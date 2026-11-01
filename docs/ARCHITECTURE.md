# Architecture

Why things are like this: [`DECISIONS.md`](DECISIONS.md) (D-xx). Message definitions: `proto/`. Rules and plugin contract: [`CONTRACTS.md`](CONTRACTS.md).

## 1. Topology

```text
Browser ──HTTPS (proxy) / HTTP localhost──► web container (React SPA + Fastify BFF)      nets: public, backend
                                              │ gRPC / TCP / mTLS
 ┌────────────────────────────────── server container ──────────────────────────────┐  nets: backend, egress
 │ Watchdog (PID 1) ──spawns/supervises──┐                                           │
 │                                       ▼                                           │
 │   Gateway ◄──UDS──► Core ───── TCP, SCRAM ──────────────────────────► db (PostgreSQL)   net: backend
 │     ▲  ▲                                                                          │
 │     │  └─ per-plugin UDS pair ─► Plugin A / Plugin B  (own UID each)               │
 │     └──────────────────────────────┘                  │ outbound only (egress)    │
 └───────────────────────────────────────────────────────┼───────────────────────────┘
                                                         ▼  Provider APIs (e.g. Meta)
```

| Container | Contents | Published |
| --- | --- | --- |
| `web` | frontend + thin BFF | yes, `127.0.0.1:8080` by default |
| `server` | watchdog, gateway, core, plugin processes | no |
| `db` | PostgreSQL 18 | no |
| `proxy` (profile `tls`) | Caddy TLS | 80/443 |

`backend` is `internal` (no internet). `egress` is attached to `server` only. No Docker socket in any container. Hardening everywhere: read-only rootfs, `cap_drop: ALL`, `no-new-privileges`, pids/memory limits.

## 2. Server container processes

| Process | UID | Secrets | DB | Listens | Talks to |
| --- | --- | --- | --- | --- | --- |
| Watchdog | root (min. caps) | reads all, re-homes | no | `watchdog.sock` (Core UID only) | spawns children; polls health sockets |
| Gateway | 10010 | TLS server key + CA | no | TCP `:50051` (mTLS, web); core-outbound sock; per-plugin `host.sock` | Core sock; each `plugin.sock` |
| Core | 10020 | DB password, master key | **yes, only client** | `core.sock` (Gateway UID only) | PostgreSQL; Watchdog; Gateway (calls to plugins) |
| Plugin *n* | 20000+ | none (leases per call) | **no** | `plugin.sock` in its private dir | Gateway `host.sock` |

```text
/run/postflowx/            (tmpfs, created by the Watchdog)
  core.sock                Gateway UID only
  gateway-core.sock        Core UID only  (Core → plugin calls via Gateway)
  watchdog.sock            Core UID only  (+ --healthcheck as root)
  health/<name>.sock       grpc health per process; status only; connectable by the Watchdog
  plugins/<id>/host.sock   Gateway's server for that plugin (plugin → Core API)
  plugins/<id>/plugin.sock plugin's server (Core → plugin via Gateway)   ← dir: only that plugin UID + Gateway UID
  secrets/<process>/       re-homed secrets, 0400, owner = that process UID
```

## 3. Communication and identity

| From → To | Transport | Caller identified by |
| --- | --- | --- |
| Browser → BFF | HTTP(S) | session cookie (Core validates the session) |
| BFF → Gateway | gRPC / TCP / mTLS | client cert `CN=postflowx-web` |
| Gateway → Core | gRPC / UDS | socket reachable by Gateway UID only; Gateway sets `x-pfx-caller-*` |
| Core → Gateway → Plugin | gRPC / UDS | Core-only socket; Gateway routes to the target plugin |
| Plugin → Gateway → Core | gRPC / UDS | per-plugin socket dir; user context only via **call token** |
| Core → PostgreSQL | TCP | SCRAM-SHA-256, password only Core can read |
| Plugin → provider | HTTPS via `egress` | credential leased from Core |

**Forbidden:** browser → Gateway/Core; BFF → DB or plugin; plugin → DB / Docker socket / Core files / other plugin's socket; anything except `web` published; a client-supplied user/plugin ID treated as identity. Validation ≠ authorization: **Core** checks actor, capability, ownership, state on every protected call.

## 4. Responsibilities

- **Web:** serve SPA; cookie transport, CSRF/Origin; validation; error mapping; typed calls to Gateway; generic routes `GET /api/connect/{plugin}/callback` (forwards raw query + session to Core) and `GET /media/public/{token}` (Core validates, BFF streams); renders plugin descriptors as forms (escaped). No DB, no domain logic, no authority.
- **Gateway:** terminate mTLS; own plugin host sockets; assign identity; method allowlist per caller kind; size/deadline/rate limits; correlation IDs; route Core→plugin. No business authorization, no secrets (except its TLS key). Small on purpose — it is in the trusted computing base.
- **Core (one process, modules):** Auth/Sessions · Authorization · Plugin Registry (manifests, lifecycle, grants, desired state → Watchdog) · Host API (storage, accounts, credentials, media, checkpoint, audit; call tokens) · Job Manager · Secret Broker · Media · Data Access (prepared statements, migrations) · Audit/Health.
- **Watchdog:** PID 1 duties; start order and restart (backoff, crash loop); UID/caps/rlimits per child; secret re-homing; hash-verified plugin start/stop (`WatchdogControl`); health aggregation. States: `STARTING, HEALTHY, DEGRADED, UNRESPONSIVE, CRASH_LOOP, STOPPED, UNKNOWN`.
- **PostgreSQL:** state only; reachable on `backend` only.
- **Plugin:** implements `PluginService`, uses `HostService` ([`CONTRACTS.md`](CONTRACTS.md)).

## 5. Key flows

**Request:** Browser → BFF (CSRF/validate) → Gateway (mTLS, allowlist) → Core (session → actor → authorize → execute) → typed result → BFF → browser.

**Connect account (OAuth):** user picks plugin → Core `begin_connect`: single-use `state` bound to user/session (TTL 10 min) + call token → plugin `BeginConnect` returns provider URL → browser redirect → provider redirects to `/api/connect/{plugin}/callback` → BFF forwards raw params + session → Core validates and consumes `state`, mints call token → plugin `HandleCallback` exchanges the code → plugin calls `UpsertAccount` + `StoreCredential` → Core encrypts, audits.

**Publish:** composer (caption, media, account, provider options from the descriptor, schedule + IANA tz) → Core validates (schema + plugin `ValidatePost`) → job `SCHEDULED` (UTC) → scheduler claims (`SKIP LOCKED`, lease) → attempt `CLAIMED` → job-scoped call token → mark `DISPATCHED` **before** calling plugin `Publish` (with deadline) → plugin leases credential, gets media (stream or signed URL), calls provider, `CheckpointAttempt` before irreversible steps → returns outcome class → Core records, retries with backoff for retryable, audit. Timeout/crash **after dispatch** → `OUTCOME_UNKNOWN` → `Reconcile` with checkpoint; only `NOT_PUBLISHED` auto-retries, `UNDECIDABLE` waits for the user. After a Core restart: expired lease while `CLAIMED` → safe retry; while `DISPATCHED` → `OUTCOME_UNKNOWN`.

**Plugin lifecycle:** `DISCOVERED → VALIDATING → INSTALLED → ENABLED → STARTING → READY` (operator CLI installs; admin grants + enables; Core tells Watchdog; `READY` after health OK **and** `Describe` with compatible API version). Failures: `INVALID, INCOMPATIBLE, START_FAILED, UNHEALTHY, CRASH_LOOP, DISABLED, UNINSTALL_PENDING`.

## 6. Data

Schema `core` (Core only): `users, sessions, user_roles, plugins, plugin_versions, plugin_grants, social_accounts, credentials (ciphertext, key_id, expires_at, state), media, posts, publishing_jobs, job_attempts (state, lease, dispatched_at, checkpoint, external ids), plugin_data, connect_states, call_tokens, public_media_tokens (all hashed), audit_events, schema_migrations`.
Admins have **no implicit access** to other users' posts, media or credentials. Media: local volume owned by Core (0700), metadata in DB, uploads validated (magic bytes, size).

| Volume / path | Access |
| --- | --- |
| `pgdata` | `db` only |
| `media` → `/var/lib/postflowx/media` | Core only |
| `plugins` → `/var/lib/postflowx/plugins` | written by the install CLI, **read-only** in `server` |
| `/run/postflowx`, `/tmp` (tmpfs) | sockets, re-homed secrets, per-plugin temp (0700) |

## 7. Startup, health, shutdown

Compose waits for `db` health → `server`: Watchdog → Core (migrations, ready) → Gateway → plugins. `web` starts independently and shows a degraded screen if the server is down. Docker healthcheck of `server` = Watchdog aggregate (Core + Gateway); plugin failure = `DEGRADED`, not unhealthy. Shutdown: stop claiming jobs → drain in-flight attempts (≤ 30 s) → stop plugins → Gateway → Core (`stop_grace_period` 45 s). Missing observation = `UNKNOWN`, never proof of failure.
