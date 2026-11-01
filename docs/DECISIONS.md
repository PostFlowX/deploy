# Decisions

Replaces all ADRs and the open-decisions list. **These are decided — build on them.** Change one only if a checkpoint in [`ROADMAP.md`](ROADMAP.md) fails or the *Revisit if* trigger hits; then add a dated line under "Change log" (what · why · revisit-if) and fix the affected doc.

## 1. Decisions

| ID | Decision | Why | Revisit if |
| --- | --- | --- | --- |
| D-01 | One Compose project per customer: containers `web`, `server`, `db` (+ optional `proxy`, profile `tls`). Nothing else. | Simple to run and reason about | multi-host / HA becomes a goal |
| D-02 | `server` = **one container, several OS processes**: Watchdog (PID 1), Gateway, Core, one process per plugin. All talk **gRPC**: Unix sockets inside, **TCP + mTLS** web↔server. | Only Core may hold DB credentials and the key; plugin crash ≠ Core crash | a process boundary costs more than it protects |
| D-03 | **Core** owns authorization, ownership, secrets, jobs and is the **only DB client**. **Gateway** only routes, limits and assigns caller identity. Web BFF never touches the DB and is never an authority. | One authorization path | — |
| D-04 | Plugin = **native executable + manifest**, child process of the server container, **own UID**, no DB credentials / keys / Docker. **v1 runs only bundled or operator-approved plugins**; untrusted third-party code is unsupported. | Process isolation limits blast radius but is not a sandbox for hostile code | untrusted plugins become a goal → container-per-plugin + egress policy |
| D-05 | Plugins are **installed by operator CLI** (`postflowx-plugin install`, SHA-256 pinning, volume read-only at runtime). The web UI manages enable/disable, grants, config, health — **no upload**. | UI upload = remote code path; needs signing first | signing/provenance exists |
| D-06 | Networks: `public` (web only, published on `127.0.0.1:8080` by default), `backend` (**internal**, no internet), `egress` (server only, for provider APIs). **No Docker socket anywhere.** DB only on `backend`. | Smallest exposure | — |
| D-07 | **Watchdog = PID 1 supervisor**, root with minimal caps (`SETUID, SETGID, CHOWN, KILL, DAC_READ_SEARCH`, maybe `SETPCAP` → checkpoint C5). It starts/restarts/observes processes, **re-homes secrets** per process on tmpfs (0400, owner = proc UID), drops everything for children. No network listener, no Docker access, no business logic. `StartPlugin` takes only (id, version) and executes only a hash-verified file inside the plugin dir. Fallback if file-secret perms misbehave (C3): hand secrets to the watchdog via env/FD only. | UID separation needs root once | custom watchdog costs > 1 L-step → s6-overlay for the static part |
| D-08 | Plugin data = **JSONB key/value table in Core** (`plugin_data`), scoped by plugin + owner (owner set by Core from the call token). **No plugin schemas, DDL, SQL.** | Removes a whole risk class | a plugin needs relational data |
| D-09 | **Declarative plugin UI:** plugin returns a descriptor (restricted JSON-Schema subset); the web frontend renders it. Plugin strings are untrusted (escaped). No plugin JS/HTML in the browser. | Tiny attack surface | iframe UIs wanted |
| D-10 | **Call tokens:** every user-scoped work item is *initiated by Core* with an opaque token bound to (plugin, user, purpose, scope, expiry ≤ call deadline). The plugin attaches it to Host API calls; Core checks it against the Gateway-assigned plugin identity. A plugin can never choose a user. | No impersonation by construction | — |
| D-11 | **Publishing contract:** Core owns posts/jobs/attempts/state machine. Plugin returns one outcome class (`PUBLISHED, RETRYABLE_FAILURE, RATE_LIMITED, AUTH_FAILURE, PERMANENT_FAILURE, UNKNOWN`). Plugin calls `CheckpointAttempt` before irreversible steps; ambiguous result → `OUTCOME_UNKNOWN` → `Reconcile` (`PUBLISHED / NOT_PUBLISHED / UNDECIDABLE`). Only `NOT_PUBLISHED` retries automatically. | No duplicate/lost posts | — |
| D-12 | **Credentials:** Core stores encrypted; plugin **leases plaintext per call** (memory only, never log/persist), every lease audited. Format in §2. | Instagram plugin must call the API itself | untrusted plugins → Core-side provider calls |
| D-13 | **Time/scheduling policy** in §2. | DST bugs are silent | — |
| D-14 | **Sessions/CSRF/passwords** in §2. | | multi-instance server or external IdP |
| D-15 | **DB:** libpqxx, prepared statements only; own migration runner; two roles; UUID ids. §2. | | — |
| D-16 | **Admin bootstrap** via CLI only (§2). No default credentials, no "first visitor wins". | | — |
| D-17 | **Stack:** C++20 server (gate: checkpoint C1), TypeScript + Fastify BFF, React + Vite frontend (TS strict), PostgreSQL 18, gRPC + Protobuf, Docker Compose. vcpkg for C++ deps. Libs: gRPC, protobuf, libsodium, libpqxx, GoogleTest, spdlog (JSON logs). | Maintainer wants to write the server in C++ | C1 fail rule hits → Go/Rust, contracts unchanged |
| D-18 | **Media:** local volume behind `MediaStorage`; providers fetch via **signed, short-lived public URLs** served by the BFF (`/media/public/{token}`, validated by Core). HTTPS (profile `tls` or own proxy) is mandatory for Instagram. | Meta fetches media by URL | S3 needed |
| D-19 | **Repos:** `postflowx-deploy` (this; Compose, docs, **`proto/`** = contracts), `postflowx-server` (+ `sdk/`, `plugins/demo/`), `postflowx-web`, later `postflowx-plugin-instagram`. Others pin a deploy tag in `PROTO_REF` and fetch only `proto/`. Contract version = deploy tag. | One source of truth | — |
| D-20 | **License:** *open — your call.* MIT, or AGPL-3.0 if you don't want closed hosted forks. Needed before the first outside contribution, not before coding. | | |

## 2. Fixed defaults (no research needed)

### **D-14 Sessions / CSRF / passwords**

- Session token: 32 random bytes (CSPRNG), base64url; DB stores only **SHA-256(token)**.
- Cookie: `HttpOnly; Secure; SameSite=Lax; Path=/`; name `__Host-pfx_session` in production, `pfx_session` in dev over `http://localhost` (the `__Host-` prefix needs HTTPS).
- Lifetimes: idle 12 h, absolute 7 days; rotate on login and on privilege change; logout deletes server-side; admin can revoke all sessions of a user.
- CSRF: `Origin` check on every non-GET + `X-CSRF-Token` header for mutations.
- Login rate limit: 5 failures / 15 min per account+IP, then exponential delay.
- Passwords: min 12 chars, no composition rules; **Argon2id via libsodium** `crypto_pwhash_str` at MODERATE (benchmark once; if > ~1 s on your host use INTERACTIVE).

### **D-12 Credential encryption**

- libsodium **XChaCha20-Poly1305** (`crypto_aead_xchacha20poly1305_ietf_*`).
- Blob: `0x01 | key_id (4 B) | nonce (24 B) | ciphertext+tag`. AAD = `"pfx-cred-v1" | account_id`.
- Master key: 32 random bytes, base64 in secret file `core_master_key`; derive a subkey with `crypto_kdf_derive_from_key` (context `"pfxcreds"`). `key_id` = first 4 bytes of SHA-256(master key).
- Rotation (not in v0.1, manual procedure in README): add `core_master_key_prev`, re-encrypt, remove.
- **Back up the key separately from DB backups; without it credentials are unrecoverable.**
- Memory: `sodium_memzero` after use; secret values live in a wrapper type that cannot be printed/logged.

### **D-13 Time**

- Store `run_at` (UTC) + IANA zone. Reference clock = DB `now()`.
- Local time in a DST **gap** → shifted forward by the gap (`Europe/Berlin` 2027-03-28 02:30 → 03:30 local = 01:30 UTC). **Overlap** → first occurrence (2027-10-31 02:30 → 00:30 UTC). (Vectors verified with Python `zoneinfo`.) UI shows the resolved instant.
- Late job: runs if within `missed_window` (15 min), else `FAILED(MISSED_WINDOW)` and the user must reschedule.
- tz library: C++20 `<chrono>` if your compiler has `zoned_time`, else Howard Hinnant's `date` (vcpkg) with system tzdata.
- Scheduler: poll every 5 s, lease 5 min with heartbeat, default 5 concurrent attempts. Retries: backoff 1 min → 5 min → 30 min → 2 h, max 5 attempts (configurable); `RATE_LIMITED` honors `retry_after`.

### **D-15 Database**

- Schema `core`; role `pfx_owner` (migrations, DDL) and `pfx_app` (DML only); `REVOKE CREATE ON SCHEMA public`; `ALTER ROLE pfx_app SET search_path = core`.
- Migrations: `migrations/NNNN_name.sql`, forward-only, checksum stored, advisory lock, one transaction each.
- `statement_timeout` 30 s, `lock_timeout` 5 s. IDs: UUID (`gen_random_uuid()`). All timestamps UTC.
- No SQL identifier ever comes from external input (there are no dynamic schemas).

### **D-16 Admin bootstrap**

- `docker compose run --rm server postflowx-admin create-admin`: password via TTY only (never argv/env), refuses if an admin exists, writes an audit event.

## 3. Verified (fill in while building; one line each)

| Check | Step | Result · date · versions |
| --- | --- | --- |
| C1 C++ build reproducible (cold/warm time) | 1 | |
| C2 mTLS rejects bad certs; client CN readable | 1 | |
| C3 secret file perms + `DAC_READ_SEARCH` (rootful / rootless) | 1 | |
| C4 PG18 volume path, internal network, read-only rootfs, image digests | 1 | |
| C5 plugin-UID isolation; `SETPCAP` needed? | 2 | |
| C6 Gateway generic proxy vs typed forwarders | 3 | |
| C7 per-plugin socket dir permissions | 3 | |

## 4. Change log

| Date | Change | Why | Revisit if |
| --- | --- | --- | --- |
| 2026-11-01 | Lean doc set; spikes replaced by checkpoints C1–C7 inside Steps 1–3 | Solo speed; same risk checks, no throw-away code | a checkpoint fails late and costs > 1 week |
