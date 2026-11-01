# Roadmap — work top to bottom

Goal: **(A) infrastructure running end to end ("Infra v0.1")**, then **(B) Instagram plugin** in its own repo.
Structure/decisions: [`ARCHITECTURE.md`](ARCHITECTURE.md) · [`CONTRACTS.md`](CONTRACTS.md) · [`DECISIONS.md`](DECISIONS.md) · [`SECURITY.md`](SECURITY.md) · [`FEATURES.md`](FEATURES.md).
Sizes: **S** ≤ 3 days · **M** 1–2 weeks · **L** 3–4 weeks (solo, part-time; recalibrate after Step 1).

## Rules (5)
1. One step at a time. A step is done when its **Done when** line is true *and* its tests run.
2. **No research needed:** defaults are decided in `DECISIONS.md`. Only deviate when a checkpoint fails.
3. **Checkpoints (C1–C7) replace separate spikes.** They are quick checks *inside* the real build. Each has a fail rule — if it fails, apply the fallback, write one line into `DECISIONS.md` ("Verified"), move on. Risky things come first (Steps 1–3) so problems show up early.
4. `main` stays runnable. Tests ship with the feature. Anything not in the current step goes to "Later".
5. Change of a boundary, trust rule or the plugin contract → one dated entry in `DECISIONS.md` (3 lines: what, why, revisit-if).

## Overview
```text
0 Setup → 1 Walking skeleton (+C1–C4) → 2 Watchdog (+C5) → 3 Gateway (+C6,C7) → 4 Core foundation
   → 5 Auth → 6 Web shell → 7 Plugin registry → 8 Host API + SDK + demo plugin (freeze contract)
   → 9 Durable jobs → 10 Web: accounts/composer/jobs → 11 Ops + release gate = Infra v0.1
Phase B: P0 Instagram research+repo → P1 connect → P2 publish → P3 schedule+errors → P4 release v0.2
```

---

## Phase A — Infrastructure

### Step 0 — Setup · S
- [ ] Commit your current repo state (the long docs stay in git history), then add this lean set.
- [ ] Create repos `postflowx-server` (watchdog, gateway, core, **sdk/**, **plugins/demo/**) and `postflowx-web`. README + `.gitignore` each.
- [ ] Pick a license (MIT, or AGPL-3.0 if you don't want closed hosted forks) → `LICENSE` in every repo.
- [ ] In server and web repos: `PROTO_REF` (deploy tag/commit) + `scripts/sync-proto.sh` (sparse-clone only `proto/`, generated code is gitignored).
- [ ] `bash scripts/init-secrets.sh && cp .env.example .env`
- **Done when:** repos exist, `docker compose config -q` passes.

### Step 1 — Walking skeleton + checkpoints C1–C4 · L
Build the thinnest path **browser → web → gRPC/mTLS → server → PostgreSQL**.
- [ ] **server:** multi-stage Dockerfile, vcpkg manifest with pinned baseline (`grpc`, `protobuf`, `libsodium`, `libpqxx`), CMake, ASan/UBSan target. Stub binary: gRPC on TCP `:50051` with mTLS (client cert required, read client CN), gRPC health, `Ping` → `SELECT 1` (password from `/run/secrets/db_password`), `--healthcheck` flag.
- [ ] **web:** Fastify, `/healthz`, `/api/status` (gRPC call over mTLS via `@grpc/grpc-js`, TS stubs generated from `proto/`) → `{"web","server","db"}`. `USER 10030`, writes only to `/tmp`.
- [ ] **CI** per repo (GitHub Actions): build, tests, sanitizer job, lint. One evening.
- [ ] **`scripts/smoke.sh`** (deploy repo): `compose up -d --build --wait` → status ok · stop db → db down/server degraded · stop server → web still serves UI shell · restart keeps data · only `127.0.0.1:8080` published.
- **C1 build:** one command builds from clean clone; warm rebuild < ~2 min. *Fail rule:* stuck > 1 week → try apt packages or Conan; > 2 weeks total → switch server language to Go/Rust (contracts in `proto/` stay).
- **C2 mTLS:** no cert / wrong CA / wrong SAN are rejected; server can read the client CN. *Fallback:* allowlist by cert fingerprint.
- **C3 secrets** (run once, rootful and, if you can, rootless):
  ```bash
  docker run --rm --cap-drop ALL --cap-add DAC_READ_SEARCH --cap-add SETUID --cap-add SETGID \
    -v "$PWD/secrets/db_password:/run/secrets/db_password:ro" debian:12-slim bash -c '
    cat /run/secrets/db_password >/dev/null && echo "root: OK" || echo "root: DENIED";
    setpriv --reuid=20001 --regid=20001 --clear-groups cat /run/secrets/db_password >/dev/null 2>&1 \
      && echo "uid 20001: OK (BAD)" || echo "uid 20001: denied (GOOD)"'
  ```
  Expect root OK / 20001 denied. *Fallback:* hand secrets to the watchdog via env/FD only (D-07).
- **C4 stack:** PG18 data survives `down`/`up` (volume path `/var/lib/postgresql`); `backend` is internal (no internet from a container on it); read-only rootfs + tmpfs work; pin image digests.
- **Done when:** `smoke.sh` passes and C1–C4 are noted in `DECISIONS.md` → *Verified*.

### Step 2 — Watchdog (PID 1) + checkpoint C5 · L
- [ ] Reap zombies, forward SIGTERM, ordered start (core → gateway → plugins) and shutdown (drain → plugins → gateway → core); static process list first.
- [ ] Per child: own UID/GID, drop capabilities, `no_new_privs`, non-dumpable, rlimits, clean env, private tmp, cwd.
- [ ] Create `/run/postflowx` socket dirs with permissions; **re-home secrets** to `/run/postflowx/secrets/<proc>/` (0400, owner = proc UID).
- [ ] Health sockets (`grpc.health.v1`) polled every 5 s; restart with backoff 1 s→60 s; crash loop = 5 failures / 5 min; `--healthcheck` = core+gateway ready (plugins only *degrade*); read-only status API; child stdout/stderr → tagged JSON logs.
- **C5 isolation:** `scripts/security-smoke.sh` runs as the "plugin" UID (`setpriv`) and must be **denied**: `/run/secrets/*`, `/run/postflowx/secrets/*`, `/proc/<core>/{environ,mem,fd}`, `/proc/1/environ`, `kill -0 <core>`, `ls /var/lib/postflowx/media`, ptrace of core. Child shows `NoNewPrivs: 1` and empty `Cap*`. *Note:* dropping the bounding set may need `CAP_SETPCAP` → add it to `cap_add`, or skip (setuid + `no_new_privs` already suffice).
- **Done when:** security-smoke passes; `kill -9` core → restarted; `docker stop` clean within 45 s; container health reflects core+gateway.

### Step 3 — Gateway + checkpoints C6, C7 · M
- [ ] mTLS TCP listener (web); UDS: core-inbound, core-outbound, one host socket per plugin; assign `x-pfx-caller-*`, strip client `x-pfx-*`; method allowlist per caller kind; limits (4 MiB message; deadlines 30 s / publish 120 s default, 10 min max); correlation IDs; route core→plugin.
- **C6 proxy:** try generic proxying (opaque bytes) for ≤ 1 day. *Fallback:* typed forwarders per RPC.
- **C7 socket identity:** per-plugin dir only accessible to that plugin UID + gateway UID; other UID gets EACCES. (Peer-credentials not required.)
- **Done when:** unary + streaming pass through; rejected: no cert, wrong caller kind, forged `x-pfx-*`, oversized, expired deadline, unknown method/version.

### Step 4 — Core foundation · L
- [ ] Module skeleton; libpqxx with prepared statements only; migration runner; DB roles (owner for migrations, app role DML only); `REVOKE CREATE ON SCHEMA public`; schema `core`, `search_path` fixed.
- [ ] Initial tables: `users, sessions, audit_events, plugins (skeleton), schema_migrations`.
- [ ] Dispatcher, audit model, health detail (DB), error mapping (`ErrorInfo`), drain interface.
- **Done when:** migrations idempotent from empty; app role cannot DDL; Gateway→Core `Health` shows DB status; audit event written and read; DB errors never reach clients.

### Step 5 — Auth & authorization · L
- [ ] `postflowx-admin create-admin` (TTY password, refuses if an admin exists); Argon2id; sessions, login/logout/me; login rate limit; admin user CRUD + roles.
- [ ] **Ownership helper:** every query scoped by owner; foreign/unknown = `NOT_FOUND`. Audit security events.
- **Done when:** cross-user and privilege-escalation tests pass; client-supplied user IDs are ignored; admin cannot read others' content.

### Step 6 — Web shell · M
- [ ] BFF: cookie transport, CSRF/Origin check, error mapping, degraded mode, CSP/security headers. React: login, nav, users (admin), health (admin).
- **Done when:** demo: login admin → create user → login as user; no token in localStorage/URLs; degraded screen when server is down.

### Step 7 — Plugin registry & lifecycle · L
- [ ] Strict manifest validation; `postflowx-plugin install` CLI (validates, pins SHA-256 of every file; volume read-only at runtime).
- [ ] Registry tables + lifecycle states; capability review/grant/revoke (audited); enable/disable → Watchdog `StartPlugin/StopPlugin` (UID pool, path containment, hash check); per-plugin sockets via Gateway; health, crash loop; admin UI plugin page; uninstall asks retain/delete.
- **Done when:** invalid or hash-mismatched plugin cannot start; revoking a grant works without restart; `security-smoke.sh` passes again with a real plugin process.

### Step 8 — Host API, SDK, demo plugin · L (do in this order)
- [ ] **8a** call tokens + storage (JSONB KV, scopes, quotas, versions) + audit append.
- [ ] **8b** credentials (encryption per D-12: store/lease, audited, states) + accounts.
- [ ] **8c** media: `MediaStorage` (local), upload validation (magic bytes, size), `OpenMedia`, signed public URL + BFF `/media/public/{token}`.
- [ ] **8d** plugin service: `Describe` (schema subset check), `BeginConnect/HandleCallback` with Core-managed `state` + generic BFF callback route, `ValidatePost`, manifest `tasks` scheduler.
- [ ] **8e** `sdk/` (stubs + helper lib) and `plugins/demo/` — fake provider with failure injection: transient error, rate limit, auth failure, timeout/`UNKNOWN`.
- **Done when:** demo plugin connects a fake account, stores data, leases its credential, serves a signed media URL; leases audited; no secrets in logs. **Then freeze plugin contract v1** (later changes additive only).

### Step 9 — Durable jobs · L
- [ ] `posts, publishing_jobs, job_attempts`; scheduler loop (`FOR UPDATE SKIP LOCKED`, lease, concurrency 5); attempt markers `CLAIMED → DISPATCHED` (set *before* calling the plugin); retry/backoff by outcome class; `OUTCOME_UNKNOWN` + `Reconcile`; checkpoints; cancel; idempotency keys; time policy D-13; restart recovery; drain on shutdown.
- **Done when (tests, using demo-plugin failure injection):** restart loses nothing · never-dispatched attempt retries · dispatched → `OUTCOME_UNKNOWN` → reconcile · no duplicate · DST vectors (`Europe/Berlin` 2027-03-28 02:30 gap, 2027-10-31 02:30 overlap) · missed window · token expiry · rate limit · plugin crash · Core crash mid-attempt.

### Step 10 — Web: accounts, composer, jobs, media · L
- [ ] Connect-account flow + callback; composer (schema-driven provider options, media upload, schedule + IANA tz); jobs list/detail with readable errors and `OUTCOME_UNKNOWN` resolution; plugin settings; all plugin strings escaped.
- **Done when:** full demo-plugin flow works in the browser.

### Step 11 — Ops + release gate = **Infra v0.1** · M–L
- [ ] Backup/restore script (`pg_dump` + media volume; **master key separately**) and **one restore drill**; upgrade procedure (backup → pull pinned images → migrate; rollback = restore); TLS profile (`--profile tls`) tested; images pinned by digest; release tag; README quick start.
- [ ] `security-smoke.sh` green; failure injection: kill plugin, kill core mid-attempt, stop db, stop gateway.
- **Infra v0.1 demo script:** `init-secrets` → `compose up` → create admin → create user → install demo plugin (CLI) → grant + enable → user connects demo account → schedules post with media → success → inject transient failure (retry) → inject ambiguous outcome (resolve) → `compose restart` during a running attempt loses nothing → second user sees none of the first user's data.

---

## Phase B — Instagram plugin (own repo `postflowx-plugin-instagram`, after Step 11)
Needs **no platform changes**; if it does, record why in `DECISIONS.md`.

- **P0 · S — research + repo.** Do the Meta research *now*, not before: current API/login type for publishing · eligible account types (Business/Creator, linked Page) · permissions and what needs **app review** · token types/lifetimes/refresh · publish flow (container → publish → status) · media types/limits · **public HTTPS media URL requirement and how long it must stay up** · rate/publish limits · retryable vs permanent errors · OAuth redirect rules. Note each answer with URL + date in `plugins/instagram` README. Use PostAPI for lessons only. Decide plugin language (default C++ with `sdk/`). **Done when:** package installs and reaches `READY` as a stub.
- **P1 · M — connect.** `Describe`, OAuth via `BeginConnect/HandleCallback`, long-lived token, `UpsertAccount`+`StoreCredential`, `refresh_account` task, `REAUTH_REQUIRED`; tests vs mock Meta server. **Done when:** test account connects; expiry/revocation → `REAUTH_REQUIRED`; no tokens in logs/UI.
- **P2 · M–L — publish.** Single image: create container → `CheckpointAttempt` → publish → poll; `CreatePublicMediaUrl`; outcome mapping; `Reconcile` via container ID. **Done when:** immediate post works; crash between container and publish → `OUTCOME_UNKNOWN` → reconciled.
- **P3 · M — scheduling, errors, media.** Scheduled posts via Core jobs; `retry_after`/limit handling; full error→outcome table with user messages; carousel/reel if permitted; `ValidatePost`. 
- **P4 · M — release v0.2.** Real-account test; app-review prep if public use; plugin security review (leases, logs, deps); user guide; package + install guide.

## Later (not scheduled)
AI text plugin kind (`ai_text`) · TikTok · UI plugin upload + signing · container-per-plugin + egress filtering (untrusted plugins) · iframe plugin UI · S3 media · recurring schedules · bulk ops.

## Deliberately NOT in v0.1 (saves weeks)
Landlock/seccomp · key-rotation tooling (manual procedure in README) · per-user data export · load tests · Playwright e2e (API tests + manual demo instead) · multi-version plugin rollback · separate SDK repo · UI plugin upload · ADR files/spike reports (everything lives in `DECISIONS.md`).
**Never cut:** ownership checks · secret handling · `OUTCOME_UNKNOWN` handling · restore drill · plugin-UID isolation tests.

## Old → new numbering
M0–M1 → Steps 0–1 · M2 → CI in Step 1 · M3 → 2 · M4 → 3 · M5 → 4 · M6 → 5 · M7 → 6 · M8 → 7 · M9 → 8 · M10 → 9 · M11 → 10 · M12+M13 → 11 · M0.5 → P0.
