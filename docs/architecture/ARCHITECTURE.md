# Architecture Overview

**Status:** Proposed baseline — **revision 2** (2026-10-22). Authoritative decisions live in `docs/decisions/` (ADR-0001 … ADR-0005); this document describes the resulting structure.

## 1. Deployment topology

One customer installation = one Docker Compose project with three application containers (plus an optional TLS proxy).

```text
                        Internet / LAN
                              │ HTTPS (via optional proxy) / HTTP on localhost
                              ▼
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ web container     React SPA + Fastify BFF                (network: public, backend)
 └───────────────┬──────────────────────────────────────────────────────────┘
                 │ gRPC over TCP, mutual TLS                (network: backend, internal)
 ┌───────────────▼────────────────────────── server container ──────────────┐
 │  Watchdog (PID 1, supervisor + health)                                    │
 │      │ spawns / supervises / restarts / re-homes secrets                  │
 │      ├──► Gateway ◄──UDS──► Core ───────── TCP, SCRAM ──► ┌───────────┐   │
 │      │       ▲  ▲                                          │ db        │   │
 │      │       │  └── per-plugin UDS pair ──► Plugin A       │ PostgreSQL│   │
 │      │       └───── per-plugin UDS pair ──► Plugin B       └───────────┘   │
 │      └──► Plugin processes (own UID each)                  (network: backend)│
 │                              │ outbound only (network: egress)            │
 └──────────────────────────────┼────────────────────────────────────────────┘
                                ▼
                     Provider APIs (e.g. Meta Graph API)
```

| Container | Contents | Networks | Published to host |
|---|---|---|---|
| `web` | Frontend + thin BFF | `public`, `backend` | yes (default `127.0.0.1:8080`) |
| `server` | Watchdog, Gateway, Core, plugin processes | `backend`, `egress` | no |
| `db` | PostgreSQL | `backend` | no |
| `proxy` *(optional, profile `tls`)* | Caddy TLS termination | `public` | 80/443 |

`backend` is an `internal` Docker network (no internet). `egress` is attached to `server` only, because plugins must call provider APIs. Docker Compose owns container lifecycle (start, stop, restart policy). Nothing in the stack receives the Docker socket.

### Technology baseline

C++20 server (validation gate in M0.2), TypeScript + Fastify BFF, TypeScript + React + Vite frontend, PostgreSQL, gRPC + Protocol Buffers, Docker Compose. Details and gate: ADR-0003.

## 2. Processes in the server container

| Process | UID (proposal) | Holds secrets? | DB access | Listens on | Talks to |
|---|---|---|---|---|---|
| Watchdog | root, minimal caps | reads all secret files, distributes them | no | `watchdog.sock` (Core only) | spawns all children; polls their health services |
| Gateway | 10010 | TLS server key + CA only | no | TCP `:50051` (mTLS, web only); core-outbound socket; one *host socket* per plugin | Core socket; each plugin's own socket |
| Core | 10020 | DB password, master key | **yes (only client)** | `core.sock` (Gateway UID only) | PostgreSQL; Watchdog control socket; Gateway (for calls to plugins) |
| Plugin *n* | `20000+` | none (leases credentials per call) | **no** | `plugin.sock` in its private dir | Gateway host socket (`host.sock`) |

Socket layout under `/run/postflowx/` (tmpfs, created by the Watchdog):

```text
/run/postflowx/
  core.sock                      Core's server; only Gateway UID may connect
  gateway-core.sock              Gateway's server for Core→plugin calls; only Core UID
  watchdog.sock                  Watchdog control API; only Core UID (+ healthcheck as root)
  health/<name>.sock             gRPC health service of every process; status only, connectable
                                 by the Watchdog (so health observation does not depend on the Gateway)
  plugins/<plugin_id>/host.sock  Gateway's per-plugin server (plugin → Core API)
  plugins/<plugin_id>/plugin.sock Plugin's server (Core → plugin API, via Gateway)
  secrets/<process>/...          re-homed secrets, 0400, owner = that process UID
```

Directory permissions allow exactly one plugin UID plus the Gateway UID into `plugins/<plugin_id>/`. Details and validation: ADR-0004, M0.2, M3, M4.

## 3. Communication paths and identity

| From → To | Transport | How the caller is identified |
|---|---|---|
| Browser → Web BFF | HTTP(S) | Session cookie (BFF validates transport; Core validates session) |
| Web BFF → Gateway | gRPC / TCP / mTLS | Client certificate (`CN=postflowx-web`) |
| Gateway → Core | gRPC / UDS | Socket access restricted to Gateway UID; Gateway sets `x-pfx-caller-kind/id` |
| Core → Gateway → Plugin | gRPC / UDS | Core UID-only socket; Gateway routes to the target plugin's socket |
| Plugin → Gateway → Core | gRPC / UDS | Per-plugin socket directory (+ peer credentials if available); Gateway assigns `plugin:<id>`; user context only via **call token** |
| Core → PostgreSQL | libpq / TCP | SCRAM-SHA-256, password only Core has |
| Core ↔ Watchdog | gRPC / UDS | Socket accessible to Core UID only |
| Plugin → provider API | HTTPS via `egress` | Provider credentials leased from Core |

### Forbidden paths

- Browser → Gateway/Core directly; Web BFF → PostgreSQL; Web BFF → plugin directly.
- Plugin → PostgreSQL, Docker socket, Core's files, another plugin's socket.
- Plugin → Core other than via the Gateway host socket and the documented Host API.
- Watchdog → Docker API; any container → Docker socket.
- Anything except `web` published to the host by default.
- A client-supplied user ID or plugin ID being treated as identity.

Request validation is not authorization: **Core** checks actor, capability, ownership and state for every protected operation.

## 4. Responsibilities

### Web (frontend + thin BFF)

Serves the SPA; browser-facing routes; cookie/session transport; CSRF/origin protection; request validation; error mapping; typed forwarding to the Gateway; generic OAuth-callback and public-media routes (ADR-0002); renders plugin descriptors as forms (untrusted strings escaped). No DB access, no domain logic, no authoritative authorization, no token storage in the browser.

### Gateway

Terminates mTLS from web; owns all plugin host sockets; assigns caller identity; enforces a **method allowlist per caller kind**, message-size limits, deadlines (bounded by policy), rate/concurrency limits and correlation IDs; strips client-supplied `x-pfx-*` metadata; routes Core→plugin calls. **Does not** decide business authorization, hold secrets or touch the database. It is part of the trusted computing base (T13) and is kept deliberately small.

### Core (one process, internal modules)

| Module | Responsibility |
|---|---|
| Auth & Sessions | users, password hashing, sessions, bootstrap admin |
| Authorization | roles, capability grants, ownership checks — single source of truth |
| Plugin Registry | manifests, versions, lifecycle state machine, grants, desired-state → Watchdog |
| Host API | storage, accounts, credentials, media, checkpoints, audit for plugins; call-token issuance/validation |
| Job Manager | scheduling, claim/lease, attempts, retries, outcome handling, reconcile |
| Secret Broker | encryption/decryption, key IDs, lease auditing |
| Media | upload validation, storage interface, signed public URLs |
| Data Access | prepared statements, migrations, role-separated connections |
| Audit & Health | audit events, structured logs, readiness |

### Watchdog

PID 1 duties (reap zombies, forward signals, ordered shutdown); start order and restart policy with backoff and crash-loop detection; privilege drop and rlimits per child; secret re-homing; hash-verified plugin start/stop via its control API; health observation of every child through the standard gRPC health protocol; aggregate health for the Docker healthcheck and a read-only status API for the admin UI. No network listener, no Docker access, no business logic. States: `STARTING`, `HEALTHY`, `DEGRADED`, `UNRESPONSIVE`, `CRASH_LOOP`, `STOPPED`, `UNKNOWN`.

### PostgreSQL

Persists application state. Reachable only on `backend`; the application role has DML only, a separate migration role has DDL; `CREATE` on `public` revoked; fixed `search_path`; one schema (`core`).

### Plugin

Native executable with manifest. Implements the `PluginService` (describe, connect, callback, validate, publish, reconcile, tasks); uses the Host API. Untrusted *by default in design* but **trusted by policy** in v1 (bundled/operator-approved only). Details: PLUGIN_SPEC.

## 5. Key flows

### 5.1 Browser request

1. Browser → BFF (cookie). BFF validates input, CSRF/origin; forwards a typed call with the opaque session token to the Gateway (mTLS).
2. Gateway authenticates the BFF, checks the method allowlist/limits, forwards to Core with caller metadata.
3. Core validates session → derives actor → authorizes → executes → returns a typed result.
4. BFF maps the result to a safe browser response.

### 5.2 Connect a provider account (OAuth)

1. User chooses a plugin → BFF → Core `accounts.begin_connect`. Core creates a single-use `state` (bound to user/session, short TTL) and issues a call token, then calls plugin `BeginConnect` via the Gateway.
2. Plugin returns the provider authorization URL (containing `state`); BFF redirects the browser.
3. Provider redirects to `/api/connect/{plugin_id}/callback?...` on the public web URL.
4. BFF forwards the raw parameters + session to Core `accounts.complete_connect`. Core validates and consumes `state`, binds to the session user, issues a call token, calls plugin `HandleCallback`.
5. Plugin exchanges the code with the provider, then calls Host API `UpsertAccount` and `StoreCredential` (+ optional storage). Core encrypts and stores, audits the result.

### 5.3 Create and publish (immediate or scheduled)

1. User composes a post in the frontend (caption, media, account, provider options from the descriptor schema, optional schedule + IANA time zone). Media upload goes BFF → Core (validated, stored on the media volume).
2. Core validates against the descriptor schema and calls plugin `ValidatePost`; creates the post and a **job** (`SCHEDULED`, `run_at` in UTC).
3. Job Manager claims due jobs (`FOR UPDATE SKIP LOCKED`, lease, concurrency limit), inserts an **attempt** (`CLAIMED`), mints a job-scoped call token, marks the attempt `DISPATCHED` **before** calling the plugin, then calls `Publish` through the Gateway with a deadline.
4. Plugin leases the credential, obtains media (stream or signed public URL), calls the provider, may `CheckpointAttempt` before irreversible steps, returns an outcome class.
5. Core records the outcome, maps it to a job state, schedules a retry with backoff for retryable outcomes, and writes the audit trail.
6. Timeout/crash **after dispatch** → `OUTCOME_UNKNOWN` → Core calls `Reconcile` (with checkpoint) when the plugin is available; only `NOT_PUBLISHED` allows an automatic retry, `UNDECIDABLE` waits for the user.
7. After a Core restart: leases that expired while `CLAIMED` (never dispatched) are safely retried; leases expired while `DISPATCHED` become `OUTCOME_UNKNOWN`.

### 5.4 Plugin lifecycle

`DISCOVERED → VALIDATING → INSTALLED → ENABLED(starting) → READY`. The operator CLI performs install/validate/pin (volume is read-only for the running server). In the UI the admin reviews requested capabilities, grants them and enables the plugin; Core records desired state and calls the Watchdog `StartPlugin`; the plugin becomes `READY` after a successful health check **and** `Describe` with a compatible API version. Failure states and details: PLUGIN_SPEC.

## 6. Data organization

One PostgreSQL schema `core`, owned by Core:

| Table | Purpose |
|---|---|
| `users`, `sessions`, `user_roles` | identity, hashed sessions, roles (`admin`, `user`) |
| `plugins`, `plugin_versions`, `plugin_grants` | registry, installed versions (hash-pinned), granted capabilities, lifecycle state |
| `social_accounts` | provider account per user (provider = plugin ID), status |
| `credentials` | encrypted credential payload, `key_id`, `expires_at`, state |
| `media` | media metadata (object ID, MIME, size, hash, owner); bytes on the media volume |
| `posts` | draft/content: caption, media refs, target account, provider options (JSONB) |
| `publishing_jobs`, `job_attempts` | state machine, schedule (`run_at` UTC + IANA zone), lease, attempts, checkpoint, external IDs |
| `plugin_data` | plugin key/value storage (ADR-0005) |
| `connect_states`, `call_tokens`, `public_media_tokens` | short-lived single-purpose tokens (stored hashed) |
| `audit_events` | actor, action, target, outcome, timestamp |
| `schema_migrations` | applied migrations with checksums |

Rules: every entity has a stable internal ID; timestamps in UTC; essential invariants enforced by constraints; prepared statements only; no SQL identifiers built from external input (there are no dynamic schemas). Admins have **no implicit access** to other users' posts, media or credentials; administration is application-level and the database superuser is an operator break-glass path.

## 7. Media storage

MVP: local persistent volume behind a `MediaStorage` interface, owned by the Core UID (mode `0700`); PostgreSQL stores metadata only. Uploads use generated object IDs, size/type validation (magic-byte check, not only extension), temporary staging with cleanup. Providers that fetch by URL use **signed public URLs** served by the BFF route `/media/public/{token}` (token validated by Core, expiring, revocable). S3-compatible storage is a later implementation of the same interface.

## 8. Startup, health and shutdown

- Compose starts `db` and waits for its health check; `server` starts the Watchdog → Core (migrations, readiness) → Gateway → plugins; `web` starts independently and shows a degraded screen while the server is unavailable.
- **Readiness levels:** process alive; ready to accept work; dependencies healthy; application degraded. `web` distinguishes "can serve UI" from "application operations available".
- **Docker healthcheck of `server`** = Watchdog aggregate (Core + Gateway ready). Plugin failures → *degraded* (visible in the admin UI), not *unhealthy*.
- Missing observations are `UNKNOWN`, never proof of failure; one failed observation path must not mark everything failed.
- **Shutdown:** stop claiming jobs → drain in-flight attempts (bounded) → stop plugins → stop Gateway → stop Core → exit.

## 9. Filesystem and volumes

| Path / volume | Owner / mode | Access |
|---|---|---|
| `pgdata` | postgres | `db` only |
| `media` → `/var/lib/postflowx/media` | Core UID, `0700` | Core only |
| `plugins` → `/var/lib/postflowx/plugins` | root-written by the install CLI, **read-only** in `server` | Watchdog (exec), plugins (read own files) |
| `/run/postflowx` (tmpfs) | per-path, see §2 | sockets, re-homed secrets |
| `/tmp`, per-plugin tmp (tmpfs) | `0700` per UID | bounded size |
| root filesystem of `server`/`web` | read-only | — |

## 10. Scope control

- Add a boundary only for a trust, deployment or failure-isolation need.
- Out of scope for Infra v0.1: untrusted third-party plugins, UI upload of plugins, plugin marketplace, iframe plugin UIs, S3 storage, HA/clustering, multi-tenant SaaS hosting.
