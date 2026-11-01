# Implementation Roadmap

**Revision 2 (2026-10-22).** Goal order: **(A) get the complete infrastructure running end to end, then (B) build the Instagram plugin** in its own repository against the frozen plugin contract.

**Principles**

1. One milestone at a time; each ends in a **demonstrable state** (demo) and has acceptance criteria and tests.
2. **Walking skeleton first:** a thin end-to-end path exists from M1 and is thickened milestone by milestone — no long stretches without something that runs.
3. Add tests with the feature, not at the end. Keep `main` runnable and deployable.
4. Do not implement against undocumented contracts; contracts live in `proto/` and `docs/` of this repository.
5. Time-boxed spikes before risky decisions (M0.2); disposable spike code is never merged into product repos.
6. Anything not in the current milestone goes to the backlog ("Later" list), not into the milestone.

**Size legend** (planning heuristic for one part-time developer; recalibrate after M2): **S** ≤ 3 days · **M** ≈ 1–2 weeks · **L** ≈ 3–4 weeks · anything larger is split.

## Overview

```text
PHASE A — Infrastructure ("Infra v0.1")

 M0 Contracts & spikes ─► M1 Repos + Compose + walking skeleton ─► M2 Engineering foundation
   │                                                                      │
   └─ M0.5 Instagram feasibility (doc only, parallel,                     ▼
      must finish before the M9 contract freeze)            M3 Watchdog ─► M4 Gateway ─► M5 Core foundation
                                                                                              │
                                                                          M6 Auth & authorization
                                                                           ├─► M7 Web shell & BFF
                                                                           └─► M8 Plugin registry & lifecycle
                                                                                   │
                                                                          M9 Host services + SDK + demo plugin   ◄─ contract v1 freeze
                                                                                   │
                                                                          M10 Durable publishing jobs
                                                                                   │
                                                                          M11 Web: accounts, composer, jobs, media
                                                                                   │
   M12 Operations (starts after M5, accepted after M11) ───────────────────────────┤
                                                                                   ▼
                                                                          M13 Security & release gate = Infra v0.1

PHASE B — Instagram plugin (repo postflowx-plugin-instagram)

 P0 Bootstrap & feasibility ─► P1 Connect & tokens ─► P2 Publish ─► P3 Scheduling, errors, media types ─► P4 Hardening & v0.2
```

## Risk gates (decide early, cheaply)

| # | Risk | Gate / mitigation | When |
|---|---|---|---|
| R1 | C++ toolchain + gRPC build effort out of proportion | M0.2 spike with explicit pass criteria; fallback = revisit language via ADR, contracts unchanged | M0.2 |
| R2 | In-container privilege separation does not behave as designed (UID drop, secrets, `/proc`, socket permissions, rootless Docker) | Spike items 5–6; acceptance tests re-run on the reference host in M3 and M13 | M0.2, M3 |
| R3 | Compose secret file permissions differ per runtime | M1.2 verification; fallback delivery path defined (OD-15) | M1.2 |
| R4 | Meta API / app review / account requirements block or reshape Phase B | M0.5 written feasibility, re-confirmed in P0 | M0.5, P0 |
| R5 | Scope creep and solo bandwidth | Milestone rules above; scope levers below; decide "cut or defer" at each milestone review | continuous |
| R6 | Watchdog complexity grows | Static process list first (M3), dynamic plugins later (M8); OD-13 re-evaluation | M3, M8 |

---

# Phase A — Infrastructure

## M0 — Contracts and spikes  *(size L overall)*

### M0.1 Documentation baseline  *(S)*
Cross-document consistency of boundaries, process model, ownership and plugin contract (this revision).
- **Accept when:** ADR-0001…0005, architecture, protocol, plugin spec, feature list, PRD, NFR, threat model and this roadmap contain no contradictory ownership/process assumptions; every open decision has an ID, default and resolving milestone.

### M0.2 Technical spikes  *(L, time-boxed, disposable code)*
Prove or disprove, in a container and in CI:
1. Pinned C++ build of gRPC + protobuf + libsodium + libpq in a reproducible image.
2. gRPC over UDS and over TCP+mTLS (C++ server ↔ Node `@grpc/grpc-js` client).
3. Gateway proxying with method allowlist, size limits and deadlines — generic (opaque bytes) vs. typed.
4. Caller identification on UDS (socket-directory permissions; peer credentials if exposed).
5. PID-1 watchdog launching a child under another UID with dropped capabilities, `no_new_privs`, rlimits, health check; zombie reaping; signal forwarding.
6. Secrets: plugin-UID stand-in cannot read secret files, other UIDs' `/proc/<pid>/environ|mem|fd`, Core's directories; verified rootful and (if supported) rootless.
- **Accept when:** results are written down (what worked, versions, effort, surprises), OD-01/02/13/15/21 are resolved or escalated, and ADR-0003's gate is passed or an updated ADR exists.
- **Demo:** a throw-away container showing items 2, 5, 6.

### M0.3 Proto v0 and contract workflow  *(M)*
Finalize `proto/` in this repository (draft files for `common`, `plugin`, `host`, `watchdog` already exist) and add a minimal `core` service (health, session sketch); `buf` config, lint + breaking-change CI; shared test fixtures.
- **Accept when:** a sample web→Gateway→Core `Health` and a Core→Gateway→plugin `Describe` validate in the spike environment; malformed, unauthenticated and unsupported-version messages fail closed.

### M0.4 Security and data decisions  *(M)*
Write short specs and resolve OD-03, OD-07, OD-09, OD-19, OD-20: session design and CSRF scheme; credential ciphertext envelope (nonce, `key_id`, AEAD, associated data); master-key handling and rotation; time/DST/missed-window policy; migration runner rules; admin bootstrap.
- **Accept when:** data flows and key recovery are documented; no SQL identifier comes from external input; every decision lists tests.

### M0.5 Instagram feasibility check  *(S–M, doc only, parallel)*
Produce `docs/product/INSTAGRAM_FEASIBILITY.md`: current API product to use, account types (Business/Creator, linked Page), permissions, app review requirements, supported media types and constraints, token lifetimes and refresh, rate/publishing limits, HTTPS/public-URL requirements. Read the existing PostAPI code for lessons (no porting).
- **Accept when:** explicit go/no-go, a list of any platform requirement that changes the infrastructure (HTTPS, URL TTL, polling needs), and the supported scope for v0.2. Must be done **before the plugin contract freeze at the end of M9**.

**Gate:** no implementation beyond disposable spikes until M0.1–M0.4 are accepted.

## M1 — Repositories, Compose and walking skeleton  *(M)*

### M1.1 Repositories and policies  *(S)*
Create `postflowx-server` and `postflowx-web` (next to this deploy repo); document responsibilities, versioning/tagging, branch rules and **how they fetch `proto/` at a pinned deploy-repo tag (OD-16)**; **decide license (OD-18)**, add `LICENSE` and a short `CONTRIBUTING.md`; no secrets committed.

### M1.2 Compose skeleton verified  *(S–M)*
Finalize `docker-compose.yaml`: networks (`public`, internal `backend`, `egress`), volumes, secrets, health checks, hardening flags; verify secret file permissions and capability set on the reference host (OD-15); pin versions.
- **Accept when:** a fresh clone with `scripts/init-secrets.sh` builds and starts the minimal stack; secrets behave as designed or the fallback is recorded.

### M1.3 Minimal containers  *(M)*
`web`: Fastify "hello" + health. `server`: **one stub binary** with a gRPC health service and a DB check (the real Watchdog arrives in M3). `db`: PostgreSQL.
- **Accept when:** restart preserves DB state; only `web` is published; process health vs. dependency health are distinguishable.

### M1.4 End-to-end smoke test  *(S)*
Browser → web BFF → gRPC/mTLS → server stub → PostgreSQL (`SELECT 1`), automated for healthy and each unavailable state.
- **Demo:** a page that shows "web ok · server ok · db ok" and degrades correctly when a container is stopped.

## M2 — Engineering foundation  *(M)*

CI in every repo (build, lint/format, unit tests; merges blocked on failure); C++: warnings-as-errors, clang-tidy, ASan/UBSan (TSan where relevant); `buf` checks; cross-repo contract-test job; structured JSON logging with typed secret wrappers; strict config validation (fail fast, secrets never printed); pinned base images, reproducible dev images; dependency scanning wired in.
- **Accept when:** CI runs on every change and failures block merge; logs of a test run contain no secret patterns; a deliberately introduced memory bug is caught by a sanitizer job.

## M3 — Watchdog  *(L)*

Real `postflowx-watchdog` as PID 1 with a **static** process list (stubs for Core/Gateway are fine):
- start order, readiness waiting, restart with backoff, crash-loop detection, zombie reaping, signal forwarding, ordered shutdown;
- per-process UID/GID, capability drop, `no_new_privs`, non-dumpable, rlimits, cleared environment, private tmpfs;
- socket directory creation and permissions; **secret re-homing**; health sockets + polling; aggregate `--healthcheck`; read-only status API; capture and tag child stdout/stderr.
- **Accept when:** the security tests from M0.2 are automated and pass (a test process under a "plugin" UID cannot read secrets, Core's directories or other UIDs' `/proc`); killing a child triggers backoff/crash-loop behavior; SIGTERM shuts down in order within the grace period; the container health reflects Core+Gateway, not plugins.
- **Demo:** `kill -9` Core → Watchdog restarts it → status shows restart count.

## M4 — Gateway  *(M)*

mTLS listener for web; UDS listeners (Core inbound, Core-outbound, per-plugin host sockets); caller identity assignment; stripping of `x-pfx-*`; per-caller-kind method allowlist; size/deadline/rate limits; correlation IDs; routing Core→plugin; structured logs.
- **Accept when:** contract tests cover valid, unauthenticated, wrong caller kind, forged metadata, oversized, expired-deadline and unsupported-version requests; Gateway holds no secrets other than its TLS key and cannot bypass Core authorization; fuzz smoke test passes.

## M5 — Core foundation  *(L)*

Module boundaries; DB layer (prepared statements, RAII, separate migration and runtime roles; `public` hardened; `search_path` fixed); migration runner (ordered, checksummed, advisory lock); initial `core` schema (users, sessions, audit, plugins skeleton, schema_migrations); request dispatcher; audit event model; readiness and detailed health; graceful drain interface; error mapping with `ErrorInfo`.
- **Accept when:** migrations run from an empty database and are idempotent; DB errors never reach clients; runtime role cannot do DDL; no other component holds DB credentials (verified by test); health detail visible to admins only.
- **Demo:** Gateway → Core `Health` with database status; audit event written and read.

## M6 — Authentication and authorization  *(L)*

`postflowx-admin create-admin` CLI (no default credentials); Argon2id; server-side sessions; login/logout, expiry/rotation; login rate limiting; admin user management; roles; **ownership enforcement framework** (owner-scoped data access helpers, hidden-resource semantics); audit of security events; cross-user and privilege-escalation tests.
- **Accept when:** unauthorized access fails server-side for every protected resource; no client-provided user ID can override the authenticated identity; admin has no implicit access to other users' content.

## M7 — Web shell and BFF  *(M–L)*

Fastify BFF: mTLS gRPC client, cookie/session transport, CSRF/origin protection, error mapping, degraded mode, CSP and security headers; React shell: login, navigation, admin users page, system health page; generated TypeScript stubs; e2e smoke tests.
- **Accept when:** UI shows only authorized pages; every action is re-authorized in Core; no token in local storage or URLs; degraded screen appears when the server is down.
- **Demo:** log in as admin, create a user, log in as that user, see the health page (admin only).

## M8 — Plugin registry and lifecycle  *(L)*

Manifest parser/validator (strict); `postflowx-plugin install` CLI (validation, path safety, SHA-256 pinning; read-only volume at runtime); registry tables and lifecycle state machine; capability review/grant/revoke (audited); enable/disable → Watchdog `StartPlugin`/`StopPlugin` with UID pool, hash and path-containment checks; per-plugin sockets via Gateway; health, crash handling, `CRASH_LOOP`; version switch with rollback; uninstall with data disposition; optional Landlock/seccomp (feature-detected); admin UI pages for plugins.
- **Accept when:** invalid/incompatible/hash-mismatched plugins cannot start; capability changes are auditable and take effect without restart; plugin processes carry no capabilities and cannot reach secrets (re-run of the M3 tests with real plugins); no remote installer exists.
- **Demo:** install a stub plugin with the CLI, review and grant capabilities in the UI, enable it, watch it reach `READY`, kill it and see it restart.

## M9 — Plugin host services, SDK and reference plugin  *(L, split into five)*

- **M9.1** Call tokens; Host API *storage* (JSONB key/value, scopes, quotas, optimistic versioning); *audit append*.
- **M9.2** *Credentials & accounts:* encryption envelope, `key_id`, `StoreCredential`/`LeaseCredential` with audit, credential states; `UpsertAccount`/`DeleteAccount`/`SetAccountStatus`.
- **M9.3** *Media:* `MediaStorage` interface, upload validation (magic bytes, size), `OpenMedia`, signed public media URLs and the BFF `/media/public/{token}` route.
- **M9.4** *Plugin service surface:* `Describe` (schema subset validation), `BeginConnect`/`HandleCallback` with Core-managed `state`, generic BFF callback route, `ValidatePost`, `RunTask` and the manifest-declared task scheduler.
- **M9.5** `postflowx-plugin-sdk`: stubs, C++ helper library, **reference "demo publisher" plugin** (fake provider with failure injection: transient error, rate limit, auth failure, timeout/`UNKNOWN`), local test harness, manifest validation tool.
- **Accept when:** the reference plugin reads/writes only its permitted scope; crash and malformed calls are handled; leases are audited and secrets never appear in logs; descriptor injection tests pass; M0.5 feasibility results are reflected in the contract. **Plugin contract v1 is frozen** (changes afterwards are additive and versioned).
- **Demo:** the demo plugin connects an account (fake OAuth), stores data, leases its credential, serves a signed media URL.

## M10 — Durable publishing jobs  *(L)*

`posts`, `publishing_jobs`, `job_attempts`; state machine (`SCHEDULED → RUNNING → SUCCEEDED | RETRY_WAIT | FAILED | OUTCOME_UNKNOWN | CANCELLED`); scheduler loop with claim/lease (`FOR UPDATE SKIP LOCKED`), concurrency limit; attempt markers (`CLAIMED` → `DISPATCHED`); retry/backoff by outcome class; `OUTCOME_UNKNOWN` + `Reconcile`; checkpoints; cancel; idempotency keys; timezone/DST/missed-window policy (OD-09); restart recovery; drain on shutdown; admin diagnostics.
- **Accept when:** no job disappears on restart; ambiguous outcomes are never blindly retried; never-dispatched attempts retry safely; duplicate prevention is tested; DST gap/overlap, missed schedule, token expiry, rate limit, plugin crash, Core crash during a dispatched attempt and external timeout all have tests (using the demo plugin's failure injection).
- **Demo:** schedule a demo post; `kill -9` Core mid-attempt; after restart the job is `OUTCOME_UNKNOWN`, reconcile resolves it, no duplicate.

## M11 — Web: accounts, composer, jobs, media  *(L)*

Connect-account flow including callback handling; composer with schema-driven provider options, media upload, schedule picker with IANA time zone and DST hints; jobs list/detail with user-facing error explanations and the `OUTCOME_UNKNOWN` resolution UI; plugin settings pages; accessible validation/loading/error states; responsive layout; e2e test of the full demo-plugin flow.
- **Accept when:** a user can connect a demo account, create and schedule a post with media, watch the job finish, and resolve an unknown outcome; UI shows only authorized resources; all plugin strings render escaped.

## M12 — Operations  *(L; design starts after M5, acceptance after M11)*

Backup/restore (PostgreSQL + media, consistent point in time; master key handled separately) with a **restore drill**; upgrade/rollback procedure and migration tests from the previous release; optional TLS profile (Caddy) and public-URL configuration guide; environment validation; release bundle manifest and compatibility matrix (images, proto version, plugin API range, bundled plugins); log retention; master-key rotation procedure; per-user data export/deletion; troubleshooting docs; resource-limit tuning.
- **Accept when:** clean install, upgrade and restore drills pass on the reference host; restoring without the key behaves as documented.

## M13 — Security and release gate: **Infra v0.1**  *(M)*

Threat-model review; all tests from THREAT_MODEL §7; dependency and image scans, SBOM; authorization/IPC/plugin-isolation suites on the reference host; load test against the NFR baseline; failure injection (plugin crash, Core crash mid-attempt, DB outage, Gateway outage); user and operator documentation; version-pinned, reproducible release bundle.
- **Accept when:** all P0 `[INFRA]` criteria pass; residual risks are documented; the **Infra v0.1 demo script** below passes on a fresh host.

**Infra v0.1 demo script:** `init-secrets` → `compose up` → create admin (CLI) → admin creates user → operator installs the demo plugin → admin grants capabilities and enables it → user connects a demo account → user schedules a post with media → job runs and succeeds → inject a transient failure and see retry → inject an ambiguous outcome and resolve it → `compose restart` during a running attempt loses nothing → second user cannot see the first user's data.

---

# Phase B — Instagram plugin (`postflowx-plugin-instagram`)

Starts after M13. The plugin needs **no platform changes** beyond bug fixes; if it does, the contract was wrong and an ADR records why.

## P0 — Bootstrap and feasibility  *(S)*
Create the repository from the SDK template; re-confirm `INSTAGRAM_FEASIBILITY.md` against the live API and docs of that date; register the Meta app in development mode with test accounts; fix the v0.2 scope (media types, account types); decide plugin language (OD-14); review PostAPI for reusable logic (audited and tested before reuse; no copying of credential handling); draft the descriptor and manifest.
- **Accept when:** CI builds a plugin package that installs and reaches `READY` with a stub implementation; scope and prerequisites are documented.

## P1 — Account connection and token lifecycle  *(M)*
`Describe` (OAuth2 redirect), `BeginConnect`/`HandleCallback` with Meta's flow, token exchange and long-lived token handling, `UpsertAccount` + `StoreCredential`, account status, `refresh_account` task with `REAUTH_REQUIRED` handling; tests against a mock Meta server and recorded fixtures.
- **Accept when:** an eligible test account can be connected and shows correct status; expiry/revocation paths produce `REAUTH_REQUIRED`; no tokens in logs or UI.

## P2 — Publish  *(M–L)*
Single-image post: create media container → `CheckpointAttempt` → publish → status polling; use `CreatePublicMediaUrl`; outcome mapping; `Reconcile` via the container ID; idempotency per attempt; failure-injection tests against the mock server.
- **Accept when:** an immediate post publishes on a test account; a crash between container creation and publish ends in `OUTCOME_UNKNOWN` and reconciles correctly.

## P3 — Scheduling integration, errors, media types  *(M)*
Scheduled posts via Core jobs; provider rate-limit and publishing-limit awareness (`retry_after`); complete error-class mapping with user-presentable messages; additional media types (carousel/reel) as the API permits; `ValidatePost` rules.
- **Accept when:** scheduled posts publish on time in a test environment; every documented provider error maps to an outcome class with a tested message.

## P4 — Hardening and release v0.2  *(M)*
Test with a real eligible account; app-review preparation where public use needs it; plugin security review (leases, logging, dependency scan); user guide (prerequisites, permissions, limits); package and install guide; release.
- **Accept when:** the Instagram v0.2 success criteria in the PRD are met.

---

# Phase C — Later (not scheduled)

AI text generation (`ai_text` plugin kind); TikTok after API feasibility; UI plugin upload with signing/provenance; container-per-plugin isolation, egress filtering and strict credential mode for untrusted plugins; iframe plugin UIs; S3 media storage; bulk operations and recurring schedules; SDKs for more languages.

---

## Scope levers (if time is short)

Cut or defer in this order, without breaking the Infra v0.1 demo: Landlock/seccomp hardening (M8) → per-user data export/deletion (M12) → TLS proxy profile packaging (M12; operator-provided proxy instead) → master-key rotation tooling (document manual procedure) → load-test depth (M13) → multi-version plugin rollback (M8). **Never cut:** ownership enforcement, secret handling, `OUTCOME_UNKNOWN` handling, restore drill, the plugin-UID isolation tests.

## Critical path

M0 → M1 → M2 → M3 → M4 → M5 → M6 → M8 → M9 → M10 → M11 → M13, then P0 → P4. M7 can proceed once M6's basic API is stable (before or alongside M8). M12 starts after M5 and is accepted after M11. M0.5 runs in parallel and must complete before the M9 freeze.

## Working rules

1. One milestone at a time, with small reviewable tasks.
2. Tests ship with the feature; sanitizers/lint/contract checks block merges.
3. `main` stays deployable; no hidden manual steps.
4. Backend authorization (Core) is authoritative.
5. Every persistent state transition has a defined failure path.
6. Update `FEATURE_LIST.md` status and this roadmap after each acceptance.
7. A change to a process boundary, trust assumption or the plugin contract requires an ADR and a review of dependent documents.
8. Review risks R1–R6 at every milestone boundary.
