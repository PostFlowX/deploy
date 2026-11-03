# Roadmap — work top to bottom

Goal: **(A) infrastructure running end to end ("Infra v0.1")**, then **(B) Instagram plugin** in its own repo.
Structure/decisions: [`ARCHITECTURE.md`](ARCHITECTURE.md) · [`CONTRACTS.md`](CONTRACTS.md) · [`DECISIONS.md`](DECISIONS.md) · [`SECURITY.md`](SECURITY.md) · [`FEATURES.md`](FEATURES.md).
Sizes: **S** ≤ 3 days · **M** 1–2 weeks · **L** 3–4 weeks (solo, part-time; recalibrate after Step 1).

## Rules

1. One step at a time. A step is done when its **Done when** line is true *and* its tests run.
2. **No research needed:** defaults are decided in `DECISIONS.md`. Only deviate when a checkpoint fails.
3. **Checkpoints (C1–C8) replace separate spikes.** They are quick checks *inside* the real build. Each has a fail rule — if it fails, apply the fallback, write one line into `DECISIONS.md` ("Verified"), move on. Risky things come first (Steps 1–3) so problems show up early.
4. `main` stays runnable. Tests ship with the feature. Anything not in the current step goes to "Later".
5. Change of a boundary, trust rule or the plugin contract → one dated entry in `DECISIONS.md` (3 lines: what, why, revisit-if).
6. 2 means done, 1 means WIP, [] means not started yet.

## Architecture v3 — the picture every step builds on

```text
Docker stack
 web container ──(only to the Gateway)──► server container ──(only the Gateway)──► postgres container

 server container
   Controller (PID 1, started by Docker)   starts all processes, assigns their rights, restarts crashed ones
     ├─ Watchdog        health checks (through the Gateway); asks the Controller to restart unhealthy processes
     ├─ IPC Gateway     the only door into the stack; EVERY message between processes passes here; only DB client
     ├─ Executioner     loads installed plugins as sub-processes, manages them, checks their rights
     │    └─ plugin sub-processes (Instagram, TikTok, Reddit …) — talk ONLY to the Executioner
     ├─ Plugin-Mgmt     (PMP) writes/stores plugin packages on disk so the Executioner can find them
     └─ File-System     stores files (images, JSON, …) on disk

 Plugin ──► Executioner ──► Gateway ──► target (File-System, DB, …)         plugins can reach nothing else
 Untrusted plugin request ──► Executioner holds it ──► local approval queue ──► admin answers in the web UI (or CLI)
                                         everything stays inside the stack: no external server, no network call
```

**What changed compared to v2:** the Watchdog is split in two. The **Controller** is now PID 1 and does the *starting and rights* part (spawn, UID/capabilities/limits, secrets, crash restarts). The **Watchdog** is a normal sibling process that only does *health checking*. The Executioner also **verifies the rights of every plugin sub-process** it spawns. The approval flow is specified as a **fully local mechanism**.

**Defaults I assumed — confirm or change before Steps 3–12 (they affect the contracts):**

| # | Assumption | Alternative |
| --- | --- | --- |
| N-1 | **Auth, ownership checks, audit and the master key live in the Gateway** (single door + only DB client). No separate Core. | split a "Core" out later if the Gateway grows too big |
| N-2 | **Controller = parent of all five platform processes.** Start, rights, crash detection (`waitpid`) and restart are kernel-level parent/child actions, not IPC. **Watchdog** asks every process "are you healthy?" **through the Gateway**; the Gateway itself is probed on its status-only health socket (it cannot be asked through itself). Watchdog ↔ Controller use **one private parent/child channel** with only `restart(name)`, `stop(name)`, `status()` — a deliberate exception to "everything through the Gateway", because otherwise a hung Gateway could never be restarted. | Watchdog restarts via the Gateway (a hung Gateway = deadlock) |
| N-3 | Plugin ↔ Executioner = **private inherited channel** (socketpair/UDS). Plugins have no socket to the Gateway. | per-plugin Gateway sockets |
| N-4 | Database access = **typed, named operations only** (e.g. `posts.list`) — never raw SQL / "select this table" from web or any process. | raw SQL (rejected: injection + no per-caller limits) |
| N-5 | Plugin install = **operator CLI → Plugin-Mgmt**; admin UI manages enable/trust/approvals. UI upload = Later. | UI upload now (needs signing first) |
| N-6 | Plugin package = **prebuilt executable + manifest** (`main.json`), built by the plugin author with the SDK. Your sketch shows `code/main.cpp` — **if you mean the server compiles plugins, say so**: that needs a compiler in the server image (bigger attack surface, slower install). | compile on install |
| N-7 | The **Controller gives the Executioner ambient `CAP_SETUID/SETGID` (nothing else)** so it can start plugin sub-processes under their own UIDs; the Executioner then **verifies each child's rights** (`/proc/<pid>/status`). → checkpoint **C8**. Fallback: the Controller spawns plugin children on the Executioner's request. | Controller spawns plugins always |
| N-8 | "Untrusted" = **approval gate only**. Network egress is **not** restricted in v1 → an approved plugin can still send data anywhere. Only grant what you would hand to the plugin author. | egress filtering (Later) |
| N-9 | Web server = **your own BFF** (Fastify), not Apache/nginx (your sketch crosses Apache out). | hand-written HTTP server |
| N-10 | **Approval is fully local:** policy (trust level, grants, remembered decisions) and the approval queue live in the local database; the admin answers in the web UI **or** with `postflowx-admin approvals list/allow/deny` (works even if the web container is down). "Trusted" = set by the admin locally + SHA-256 pinning from install. No external service, no signature/registry server. Timeout = deny. | remote trust service (you have no server for it) |

## Overview

```text
0 Setup → 1 Walking skeleton (+C1–C4) → 2 Controller (PID 1) (+C5) → 3 IPC Gateway: request format + hub (+C6,C7)
   → 4 Watchdog (health) → 5 Gateway data layer (DB) → 6 Auth → 7 Web shell → 8 File-System process
   → 9 Plugin-Management process → 10 Executioner (+C8) → 11 Trust & local approval
   → 12 Host API + SDK + demo plugin (freeze contract) → 13 Durable jobs
   → 14 Web: accounts/composer/jobs → 15 Ops + release gate = Infra v0.1
Phase B: P0 Instagram research+repo → P1 connect → P2 publish → P3 schedule+errors → P4 release v0.2
```

---

## Phase A — Infrastructure

### Step 0 — Setup · S

- [2] Commit your current repo state (the long docs stay in git history), then add this lean set.
- [2] Create repos `postflowx-server` (controller, watchdog, gateway, executioner, plugin-manager, filesystem, **sdk/**, **plugins/demo/**) and `postflowx-web`. README + `.gitignore` each.
- [1] Pick a license (MIT, or AGPL-3.0 if you don't want closed hosted forks) → `LICENSE` in every repo.
- [1] In server and web repos: `PROTO_REF` (deploy tag/commit) + `scripts/sync-proto.sh` (sparse-clone only `proto/`, generated code is gitignored).
- [2] `bash scripts/init-secrets.sh && cp .env.example .env`
- **Done when:** repos exist and skeleton has some kind of form (Comment: not using the ai docker-compose since i wanna write that myself my still keeping it inside this repo)

### Step 1 — Walking skeleton + checkpoints C1–C4 · L

Build the thinnest path **browser → web → gRPC/mTLS → Gateway → PostgreSQL**.

- [ ] **server:** multi-stage Dockerfile, vcpkg manifest with pinned baseline (`grpc`, `protobuf`, `libsodium`, `libpqxx`), CMake, ASan/UBSan target. Stub binary = **the Gateway stub**: gRPC on TCP `:50051` with mTLS (client cert required, read client CN), gRPC health, `Ping` → `SELECT 1` (password from `/run/secrets/db_password`), `--healthcheck` flag.
- [ ] **web:** Fastify, `/healthz`, `/api/status` (gRPC call over mTLS via `@grpc/grpc-js`, TS stubs generated from `proto/`) → `{"web","server","db"}`. `USER 10030`, writes only to `/tmp`. It may only ever connect to the Gateway.
- [ ] **Compose network split** (so "web → Gateway only" and "DB ← Gateway only" are enforced by the network, not just by code): `public` (web), `backend` (internal: web + server), **`dbnet` (internal: server + db only)**, `egress` (server). Web is *not* on `dbnet`; db is *not* on `backend`.
- [ ] **CI** per repo (GitHub Actions): build, tests, sanitizer job, lint. One evening.
- [ ] **`scripts/smoke.sh`** (deploy repo): `compose up -d --build --wait` → status ok · stop db → db down/server degraded · stop server → web still serves UI shell · restart keeps data · only `127.0.0.1:8080` published · **from the web container the db host is unreachable**.
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

  Expect root OK / 20001 denied. *Fallback:* hand secrets to the Controller via env/FD only (D-07).
- **C4 stack:** PG18 data survives `down`/`up` (volume path `/var/lib/postgresql`); `backend` and `dbnet` are internal (no internet from a container on them); read-only rootfs + tmpfs work; pin image digests.
- **Done when:** `smoke.sh` passes and C1–C4 are noted in `DECISIONS.md` → *Verified*.

### Step 2 — Controller (PID 1) + checkpoint C5 · L

The Controller starts everything and assigns rights. It is small, has **no network, no DB, no business logic**, and listens to nothing except its private channel to the Watchdog.

- [ ] Reap zombies, forward signals. **Ordered start: Gateway → File-System → Plugin-Mgmt → Executioner → Watchdog** (everyone needs the Gateway first; the Watchdog needs the others). **Shutdown in reverse — the Watchdog stops first** so it cannot trigger restarts while the stack goes down; the Executioner drains jobs and plugins before it exits. Static process list first, with stub processes.
- [ ] **Assign rights per process** from one config table: UID/GID, capabilities (all dropped; only the Executioner gets ambient `CAP_SETUID/SETGID`, see C8), `no_new_privs`, non-dumpable, rlimits, clean env, private tmp, cwd.
- [ ] Create `/run/postflowx` socket dirs with permissions; **re-home secrets** to `/run/postflowx/secrets/<proc>/` (0400, owner = proc UID): DB password + master key → **Gateway only**; every other process gets nothing.
- [ ] **Crash handling:** `waitpid` detects a dead child → restart with backoff 1 s→60 s; crash loop = 5 failures / 5 min → stop restarting that process, mark `CRASH_LOOP` (visible in status). A Gateway or Controller crash loop makes the container unhealthy so Docker takes over.
- [ ] **Private channel Controller ↔ Watchdog** (socketpair created at spawn): only `restart(name)`, `stop(name)`, `status()` for the static platform-process list + heartbeat both ways (a dead or hung Watchdog gets restarted by the Controller). No other way to talk to the Controller.
- [ ] `--healthcheck` = all five platform processes ready (**plugin** failures only *degrade*); child stdout/stderr → tagged JSON logs.
- **C5 isolation:** `scripts/security-smoke.sh` runs as a stand-in "plugin" UID (`setpriv`) and must be **denied**: `/run/secrets/*`, `/run/postflowx/secrets/*`, `/proc/<gateway>/{environ,mem,fd}`, `/proc/1/environ`, `kill -0 <gateway>`, the `media` and `plugins` volumes, ptrace of the Gateway. Each platform process shows its assigned UID, `NoNewPrivs: 1` and empty `Cap*` (Executioner: only the two ambient caps). *Note:* dropping the bounding set may need `CAP_SETPCAP` → add it to `cap_add`, or skip (setuid + `no_new_privs` already suffice).
- **Done when:** security-smoke passes; `kill -9` of any platform process (and of the Watchdog) → restarted; `docker stop` clean within 45 s with the Watchdog stopped first; container health reflects the five platform processes.

### Step 3 — IPC Gateway: request format + hub + checkpoints C6, C7 · L

- [ ] **3a — Decide the IPC request format** (short design step; write it into `CONTRACTS.md` and `proto/`): envelope (request id, sender, target process, operation, payload, deadline, actor/context, idempotency key), reply + error model, chunked streaming for large payloads (files), and the **route table: who may call whom** (deny by default). Initial routes: web → Gateway ops; Executioner → File-System / Plugin-Mgmt / DB ops / approvals; Plugin-Mgmt → DB ops (and File-System if needed); Watchdog → `health` of every process; the Controller is **not** a Gateway client.
- [ ] **3b — Hub:** every process connects *only* to the Gateway (own socket dir + UID = identity); Gateway routes to the target process; mTLS TCP listener for web = **the only way into the stack**; Gateway assigns the sender identity and strips client-supplied identity fields; route ACL; limits (4 MiB message, chunks of 64 KiB for files; deadlines 30 s / publish 120 s default, 10 min max); correlation IDs; status-only health socket for the Watchdog's direct probe.
- **C6 proxy:** try generic proxying (opaque bytes) for ≤ 1 day. *Fallback:* typed forwarders per operation.
- **C7 socket identity:** per-process socket dir only accessible to that process UID + Gateway UID; other UID gets EACCES. (Peer-credentials not required.)
- **Done when:** a message from one stub process to another arrives **only via the Gateway**; rejected: no cert, wrong sender for a route, forged identity fields, oversized, expired deadline, unknown route/version; there is no other socket between platform processes (except the Controller ↔ Watchdog channel).

### Step 4 — Watchdog (health) · S–M

- [ ] Health request to **every platform process through the Gateway** every 5 s (no direct channel); the **Gateway itself** is probed on its health socket. Plugin sub-process states come from the Executioner's report.
- [ ] Per-process state: `STARTING, HEALTHY, DEGRADED, UNRESPONSIVE, CRASH_LOOP, STOPPED, UNKNOWN`. A missing observation is `UNKNOWN`, never proof of failure. `UNRESPONSIVE` after 3 consecutive failures → `restart(name)` to the Controller.
- [ ] Publishes the status through the Gateway (admin health page reads it).
- [ ] Runs with no capabilities, no DB access, no secrets; it can **observe and request**, never start or kill by itself.
- **Done when:** a hung process (`SIGSTOP`) turns `UNRESPONSIVE` and is restarted via the Controller; a crash shows in the status; killing the Watchdog is recovered by the Controller; the Watchdog has no socket except Gateway + Controller channel.

### Step 5 — Gateway data layer (database) · L

- [ ] PostgreSQL is reachable **only** from the Gateway. **Typed named operations** (N-4); no raw SQL from web or any process; libpqxx with prepared statements only; migration runner; DB roles (owner for migrations, app role DML only); `REVOKE CREATE ON SCHEMA public`; schema `core`, `search_path` fixed.
- [ ] **Ownership rule in the data layer:** every operation on owned data takes the authenticated owner from the request context; foreign/unknown = `NOT_FOUND`.
- [ ] Initial tables: `users, sessions, audit_events, schema_migrations`; audit write op; health detail (DB); error mapping (`ErrorInfo`); drain interface.
- **Done when:** migrations idempotent from empty; app role cannot DDL; web → Gateway → DB round trip with a real operation (e.g. `users.list` stub); other processes cannot send SQL; DB errors never reach clients.

### Step 6 — Auth & authorization (in the Gateway, N-1) · L

- [ ] `postflowx-admin create-admin` (TTY password, refuses if an admin exists); Argon2id; sessions, login/logout/me; login rate limit; admin user CRUD + roles.
- [ ] **Every request entering the stack is authenticated at the Gateway** (session → actor) and authorized by route ACL + role; ownership enforced in the data layer (Step 5). Audit security events.
- **Done when:** cross-user and privilege-escalation tests pass; client-supplied user IDs are ignored; admin cannot read others' content.

### Step 7 — Web shell · M

- [ ] BFF (your own Fastify server): cookie transport, CSRF/Origin check, error mapping, degraded mode, CSP/security headers; talks **only** to the Gateway. React: login, nav, users (admin), health (admin).
- **Done when:** demo: login admin → create user → login as user; no token in localStorage/URLs; degraded screen when server is down.

### Step 8 — File-System process · M

- [ ] Stores images, JSON and other files on the `media` volume; **only this process (its UID, dir 0700)** can touch the volume; reached only through the Gateway.
- [ ] Operations: `fs.put / get / stat / delete / list` with chunked streaming; storage path derived from a generated ID — never from a client-supplied name (no path traversal); atomic writes (temp + rename); validation (magic bytes, size limit 100 MiB default, quota per owner); owner scoping; metadata rows via the Gateway.
- [ ] Signed, short-lived public media URL + web route `/media/public/{token}` (Gateway validates the token → streams from File-System).
- **Done when:** web upload → Gateway → File-System → file on disk, download works; traversal, oversize, wrong-type and foreign-owner tests fail correctly; no other process can read the volume.

### Step 9 — Plugin-Management process (PMP) · M

- [ ] Package format (decide now, document in `CONTRACTS.md`): manifest `main.json` + `code/` (prebuilt executable, see N-6) + `sha256sums`. Strict manifest validation (unknown fields rejected), path safety, size limits.
- [ ] **Only this process writes** the `plugins` volume (everyone else read-only); stores packages under `/var/lib/postflowx/plugins/<id>/<version>/`, pins SHA-256 of every file, writes registry rows via the Gateway (`plugins`, versions, trust level `trusted|untrusted`, requested/granted capabilities, lifecycle state).
- [ ] Install trigger: `postflowx-plugin install <package>` → PMP via the Gateway (N-5); list/get/enable/disable/trust/uninstall (asks retain/delete data) as typed operations; admin UI plugin page (list, trust level, capabilities, enable/disable).
- **Done when:** invalid or tampered packages are rejected; installed plugin shows up in the UI; the Executioner can read the files but not write them; capability/trust changes are audited.

### Step 10 — Executioner + checkpoint C8 · L

- [ ] Reads the registry via the Gateway; **loads enabled plugins as its own sub-processes**: verifies the pinned hash, then spawns each under a **distinct UID**, no capabilities, `no_new_privs`, rlimits, clean env, private tmp.
- [ ] **Rights check after every spawn:** read `/proc/<pid>/status` — `Uid` is the assigned one, `NoNewPrivs: 1`, `Cap*` empty. Any deviation → kill the child, mark the plugin `START_FAILED`, audit it. A plugin is `READY` only after this check **and** a successful health check.
- [ ] **Private plugin ↔ Executioner channel** (inherited socketpair/UDS). The plugin has **no** connection to the Gateway or anything else; the Executioner forwards plugin requests to the Gateway only for allowed operations (the per-request rights check is Step 11).
- [ ] Plugin lifecycle in the Executioner: start/stop/restart, crash loop, backoff, states reported to the Watchdog through the Gateway (*degraded*); graceful stop on shutdown.
- **C8 spawn & privilege drop:** can the Executioner (non-root, ambient `CAP_SETUID/SETGID` from the Controller) switch plugin children to other UIDs and drop everything? *Fallback:* the Executioner asks the Controller to spawn the child (adds one hash-checked, path-contained `spawn(plugin_id, version)` operation to the Controller channel).
- **Done when:** a stub plugin starts as a sub-process under its own UID; `kill -9` → restarted; `security-smoke.sh` passes with a real plugin process (cannot reach Gateway socket, volumes, secrets, other plugins); a hash-mismatched plugin never starts.

### Step 11 — Trust and local approval · M

- [ ] Trust level per plugin (`trusted | untrusted`, set by the admin locally) + granted capabilities. Every plugin request arriving at the Executioner is checked: **trusted + granted → forward silently; untrusted → approval needed; not granted → denied.**
- [ ] **Local approval mechanism (N-10) — nothing leaves the stack:** the Executioner holds the request and creates an approval entry (Gateway op, stored in the local DB). The admin answers **deny / allow once / allow always for this capability** either in the web UI (the BFF follows pending entries through the Gateway and pushes them to the browser via SSE) **or** with `postflowx-admin approvals list|allow|deny` (works with the web container down). The decision is stored, audited and releases or rejects the held request (`PERMISSION_DENIED`). Timeout 60 s = deny; rate limit on prompts.
- [ ] Web UI: pending-approvals list/badge, history.
- **Done when:** an untrusted demo-plugin request (e.g. file write) is blocked until the admin approves; a trusted plugin passes without a prompt; denial reaches the plugin as an error; all decisions appear in the audit log; **the whole flow works with the `egress` network detached (no internet) and also via the CLI with the web container stopped.**
- **Limit (N-8):** approval gates *what the plugin asks the platform for*; it does not restrict the plugin's own network access in v1.

### Step 12 — Host API, SDK, demo plugin · L (do in this order)

- [ ] **12a** plugin → Executioner request set (all forwarded Executioner → Gateway after the Step 11 check): storage (JSONB KV, scopes, quotas, versions), accounts, credentials, media (via File-System ops), checkpoint, audit append. **User context is held by the Executioner per call** (`call_id`); the plugin can never name a user.
- [ ] **12b** credentials: encryption per D-12, store/lease, audited, states; **master key only in the Gateway** (N-1).
- [ ] **12c** plugin service: `Describe` (schema subset check), `BeginConnect/HandleCallback` with Gateway-managed `state` + generic BFF callback route, `ValidatePost`, manifest `tasks` scheduler (in the Executioner).
- [ ] **12d** `sdk/` (stubs + helper lib) and `plugins/demo/` — fake provider with failure injection: transient error, rate limit, auth failure, timeout/`UNKNOWN`.
- **Done when:** demo plugin connects a fake account, stores data, leases its credential, serves a signed media URL; leases audited; no secrets in logs. **Then freeze plugin contract v1** (later changes additive only).

### Step 13 — Durable jobs · L

- [ ] `posts, publishing_jobs, job_attempts` (via Gateway operations); **scheduler in the Executioner** (`FOR UPDATE SKIP LOCKED`, lease, concurrency 5); attempt markers `CLAIMED → DISPATCHED` (set *before* calling the plugin); retry/backoff by outcome class; `OUTCOME_UNKNOWN` + `Reconcile`; checkpoints; cancel; idempotency keys; time policy D-13; restart recovery (also **Gateway restart must not lose or duplicate jobs**: reconnect with backoff); drain on shutdown.
- **Done when (tests, using demo-plugin failure injection):** restart loses nothing · never-dispatched attempt retries · dispatched → `OUTCOME_UNKNOWN` → reconcile · no duplicate · DST vectors (`Europe/Berlin` 2027-03-28 02:30 gap, 2027-10-31 02:30 overlap) · missed window · token expiry · rate limit · plugin crash · Executioner crash mid-attempt · Gateway restart mid-attempt.

### Step 14 — Web: accounts, composer, jobs, media · L

- [ ] Connect-account flow + callback; composer (schema-driven provider options, media upload, schedule + IANA tz); jobs list/detail with readable errors and `OUTCOME_UNKNOWN` resolution; plugin settings; all plugin strings escaped.
- **Done when:** full demo-plugin flow works in the browser.

### Step 15 — Ops + release gate = **Infra v0.1** · M–L

- [ ] Backup/restore script (`pg_dump` + media volume + plugins volume; **master key separately**) and **one restore drill**; upgrade procedure (backup → pull pinned images → migrate; rollback = restore); TLS profile (`--profile tls`) tested; images pinned by digest; release tag; README quick start.
- [ ] `security-smoke.sh` green; failure injection: kill plugin, kill Executioner mid-attempt, kill Gateway, kill Watchdog, stop db, kill File-System / Plugin-Mgmt, kill Controller (container restarts via Docker).
- **Infra v0.1 demo script:** `init-secrets` → `compose up` → create admin → create user → install demo plugin (CLI) → trust level + grant + enable → **untrusted plugin request is held until the admin approves** (UI, and once via CLI) → user connects demo account → schedules post with media → success → inject transient failure (retry) → inject ambiguous outcome (resolve) → `compose restart` during a running attempt loses nothing → second user sees none of the first user's data.

---

## Phase B — Instagram plugin (own repo `postflowx-plugin-instagram`, after Step 15)

Needs **no platform changes**; if it does, record why in `DECISIONS.md`.

- **P0 · S — research + repo.** Do the Meta research *now*, not before: current API/login type for publishing · eligible account types (Business/Creator, linked Page) · permissions and what needs **app review** · token types/lifetimes/refresh · publish flow (container → publish → status) · media types/limits · **public HTTPS media URL requirement and how long it must stay up** · rate/publish limits · retryable vs permanent errors · OAuth redirect rules. Note each answer with URL + date in `plugins/instagram` README. Use PostAPI for lessons only. Decide plugin language (default C++ with `sdk/`). **Done when:** package installs and reaches `READY` as a stub.
- **P1 · M — connect.** `Describe`, OAuth via `BeginConnect/HandleCallback`, long-lived token, `UpsertAccount`+`StoreCredential`, `refresh_account` task, `REAUTH_REQUIRED`; tests vs mock Meta server. **Done when:** test account connects; expiry/revocation → `REAUTH_REQUIRED`; no tokens in logs/UI.
- **P2 · M–L — publish.** Single image: create container → `CheckpointAttempt` → publish → poll; `CreatePublicMediaUrl`; outcome mapping; `Reconcile` via container ID. **Done when:** immediate post works; crash between container and publish → `OUTCOME_UNKNOWN` → reconciled.
- **P3 · M — scheduling, errors, media.** Scheduled posts via platform jobs; `retry_after`/limit handling; full error→outcome table with user messages; carousel/reel if permitted; `ValidatePost`.
- **P4 · M — release v0.2.** Real-account test; app-review prep if public use; plugin security review (leases, logs, deps); user guide; package + install guide.

## Later (not scheduled)

AI text plugin kind (`ai_text`) · TikTok · Reddit · UI plugin upload + signing · **egress filtering / container-per-plugin for truly untrusted plugins** · iframe plugin UI · S3 media · recurring schedules · bulk ops · splitting a separate "Core" out of the Gateway if it grows too big.

## Deliberately NOT in v0.1 (saves weeks)

Landlock/seccomp · key-rotation tooling (manual procedure in README) · per-user data export · load tests · Playwright e2e (API tests + manual demo instead) · multi-version plugin rollback · separate SDK repo · UI plugin upload · plugin network sandbox · ADR files/spike reports (everything lives in `DECISIONS.md`).
**Never cut:** ownership checks · secret handling · `OUTCOME_UNKNOWN` handling · restore drill · plugin-UID isolation tests · Gateway route ACL (deny by default).

## Old → new numbering

v2 → this version: 0→0 · 1→1 · 2 *(Watchdog: start + health)*→2 *Controller* + 4 *Watchdog* · 3→3 · 4→5 · 5→6 · 6→7 · 7 *(File-System)*→8 · 8 *(Plugin-Mgmt)*→9 · 9 *(Executioner)*→10 · 10 *(approval)*→11 · 11→12 · 12→13 · 13→14 · 14→15.
Lean v1 → v3: 0,1 same · 2→2+4 · 3→3 · 4 *(Core foundation)*→5 · 5→6 · 6→7 · 7 *(plugin registry)*→9+10 · 8 *(Host API)*→12 (media → 8) · 9→13 · 10→14 · 11→15.
Detailed v0 (M-numbers): M0–M1 → Steps 0–1 · M0.5 → P0.
