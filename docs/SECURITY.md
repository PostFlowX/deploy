# Security and quality targets

Threat model + non-functional requirements in one place. Decisions behind it: [`DECISIONS.md`](DECISIONS.md).

## 1. Assets and trust model

**Assets:** provider tokens, user identities/sessions/password hashes, posts/media/schedules, the **master key** and DB password, internal TLS keys, plugin packages (pinned hashes), audit trail, availability.
**In scope:** remote attacker on the web entry point · authenticated user reaching another user's data/admin functions · buggy or compromised bundled/approved plugin · compromised web container · malicious provider content (callback params, API responses, descriptors) · operator mistakes/crashes · supply chain.
**Assumptions:** host root can read everything · **v1 plugins are trusted by policy** (process isolation limits blast radius, it is no sandbox for hostile code) · containers are not VM boundaries · single customer per host.

## 2. Threats (T) → mitigations

| ID | Threat | Mitigation | Residual |
| --- | --- | --- | --- |
| T0 | CSRF / weak session | cookie flags, Origin check + CSRF header, hashed server-side sessions, rotation, idle/absolute expiry, rate limit (D-14) | XSS = session theft → CSP, escaping |
| T1 | User A reads user B's data | actor from session/call token only; owner check on every operation; deny by default; hidden resources = `NOT_FOUND` | — |
| T2 | Malicious/compromised plugin | no DB creds/keys; grants reviewed; call tokens; own UID, no caps, `no_new_privs`, rlimits, clean env; read-only hash-pinned plugin dir; per-plugin limits; audit | can misuse what it's granted, can use any egress host, can try the DB port (auth stops it) → only trusted plugins in v1 |
| T3 | Plugin UI attacks the app | n/a in v1 (no plugin JS); revisit with iframe UIs | — |
| T4 | Call-token misuse | 256-bit random, stored hashed, bound to (plugin, user, purpose, scope, expiry); compared with Gateway-assigned identity; revoked on disable | — |
| T5 | SQL injection / schema confusion | prepared statements only; no dynamic identifiers; `public` CREATE revoked; fixed `search_path`; two DB roles | — |
| T6 | Key/secret compromise | AEAD, key outside DB and DB backups, `key_id`, secrets on tmpfs per UID, non-loggable secret type | host root |
| T7 | Malicious package / supply chain | install only via operator CLI; SHA-256 pinning checked by Watchdog before exec; read-only volume; pinned image digests; scans | signing comes later |
| T8 | SSRF / unwanted outbound | `backend` has no internet; only server has `egress`; Core/Gateway fetch no user URLs; plugins validate URLs | egress not filtered in v1 |
| T9 | Duplicate / lost publish | durable jobs; `DISPATCHED` before call; `OUTCOME_UNKNOWN`; checkpoint + reconcile; idempotency keys; no auto-retry unless `NOT_PUBLISHED` | no exactly-once promise |
| T10 | Resource exhaustion | container + per-process limits; size/rate/concurrency limits; quotas; bounded queues; crash-loop stop | — |
| T11 | Monitoring blind spots | health sockets independent of Gateway; `UNKNOWN` ≠ failure; Docker handles Watchdog death | — |
| T12 | Bad backup/upgrade | DB + media backup together, key separate; checksummed transactional migrations; backup before upgrade; restore drill | — |
| T13 | Gateway identity spoofing | tiny, no secrets but TLS key; strips `x-pfx-*`; identity from cert/socket only; Core re-validates call tokens; Core socket Gateway-only; negative tests | Gateway is in the trusted base for web identity |
| T14 | Privileged Watchdog abused | min caps; no network listener, no Docker; control socket Core-only; `StartPlugin` = (id, version) → hash-verified file in plugin dir (no traversal/symlinks); children drop all caps | memory bug in Watchdog = high impact → keep it small |
| T15 | Plugin reads Core secrets / DB | distinct UIDs; secrets 0400 owned by consumer on tmpfs; `/run/secrets` unreadable to plugin UIDs; non-dumpable; Core dirs 0700; DB SCRAM; DB only on `backend` | DB port reachable from plugin netns; kernel escapes |
| T16 | Credential lease abuse | grant + scoped call token; every lease audited; short lease; instant grant revocation | compromised trusted plugin can exfiltrate tokens it legitimately leases |
| T17 | Public media endpoint abuse | 256-bit hashed tokens, short TTL, revocable, single object; Core validates each request; no listing; rate limit; no cookies | — |
| T18 | OAuth callback abuse | Core-made single-use `state` bound to session user (TTL 10 min); BFF forwards raw params; allowlisted plugin IDs; fixed redirect targets | — |
| T19 | Malicious descriptor content | restricted schema subset; escaped text only; SVG sanitized + size-limited; strict CSP | — |

## 3. Targets (NFR) — measure, don't over-engineer

- **Reliability:** clean install works from the docs; Core not ready until migrations done; restarts lose no jobs; plugin crash never affects Core/Gateway/other plugins (stack `DEGRADED`, container healthy); restart backoff 1 s→60 s, crash loop = 5 in 5 min; shutdown drains ≤ 30 s, `stop_grace_period` 45 s; restore drill before release.
- **Performance baseline (not a scale promise):** 10 concurrent users, 100 pending jobs, 5 concurrent attempts; authenticated read BFF→Core p95 < 500 ms; Gateway hop p95 < 20 ms (UDS) / < 100 ms (mTLS); upload limit 100 MiB per item (chunked 64 KiB); everything bounded (queues, bodies, uploads, tasks, storage quotas). Defaults: `server` 1 GiB / 512 pids, `web` 512 MiB / 128 pids, plugin 256 MiB.
- **Security:** only web published, default `127.0.0.1`; production refuses to run without mTLS; Argon2id; no secrets in logs; authorization tests for every sensitive operation; C++ with warnings-as-errors, ASan/UBSan in CI, clang-tidy.
- **Observability:** JSON logs with timestamp, process, severity, request ID, event type; redaction **by construction** (secret wrapper type); plugin stdout/stderr tagged by the Watchdog; attempts log job/attempt/plugin/outcome/timing; audit = actor, action, target, outcome, time (no secret values); retention 14 days logs, 90 days audit/jobs.
- **Data:** stable IDs, UTC timestamps + IANA zone, constraints for ownership/state/idempotency; migrations tested from empty and from previous release; backup = DB + media, key separately.
- **Portability:** Docker Compose on one Linux host; production images pinned by digest, never `latest`.

## 4. Must-pass tests (run in CI or `scripts/*-smoke.sh`)

1. **Cross-user:** read/write attempts per resource family; user cannot grant themselves admin/capabilities.
2. **Plugin UID (`security-smoke.sh`):** cannot read `/run/secrets/*`, `/run/postflowx/secrets/*`, Core state, media, `/proc/<other>/{environ,mem,fd}`; cannot signal/ptrace others; cannot connect to another plugin's socket; cannot authenticate to PostgreSQL.
3. **Call tokens:** expired, revoked, wrong plugin, wrong user scope, missing on user-scoped call → rejected.
4. **Gateway:** unauthenticated, wrong caller kind, forged `x-pfx-*`, oversized, expired deadline, unsupported version → rejected + logged.
5. **Watchdog:** `StartPlugin` with traversal, symlink escape, hash mismatch, unknown plugin → rejected; crash loop stops restarts; children carry no caps.
6. **Descriptor/UI:** script/HTML in plugin strings and SVG icons does not execute.
7. **OAuth:** reused, expired, foreign-session, missing `state` → rejected. **Public media:** expired, revoked, guessed, cross-object tokens → rejected.
8. **Secrets:** ciphertext useless without the key; logs/audit contain no token values; restore drill with and without the key.
9. **Failure injection:** plugin crash, resource exhaustion, Gateway/DB outage, Core crash **during a dispatched attempt** → no corruption, no duplicates (`OUTCOME_UNKNOWN` path exercised).

## 5. Residual risks

Host root sees everything · a trusted plugin can misuse any granted capability/lease and has open egress · isolation depends on kernel/runtime · Gateway is in the trusted base, Watchdog is a small privileged component · provider APIs may change or reject; ambiguous publish results can't always be resolved automatically.
