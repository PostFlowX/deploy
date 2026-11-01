# Non-Functional Requirements

**Status:** Initial measurable targets — **revision 2** (2026-10-22). Values are proposed baselines; change them only with an ADR and corresponding tests. Nothing is "achieved" until measured in CI or a documented benchmark environment.

## 1. Reliability and recovery

- The Compose stack starts from a clean installation using the documented steps without hidden manual setup.
- Core does not report ready until all required migrations have completed.
- A restart of any process or container does not erase queued jobs or attempt history.
- **Process failure isolation:** a plugin crash/hang must not affect Core, Gateway, other plugins or job state; the `server` container stays healthy (stack `DEGRADED`). Core or Gateway crash loops make the container unhealthy so Docker's restart policy applies.
- **Restart policy inside the container:** exponential backoff (initial 1 s, max 60 s), crash-loop threshold (default 5 failures in 5 min → `CRASH_LOOP`, no further restarts, admin-visible).
- **Graceful shutdown:** stop claiming jobs → drain in-flight attempts (bounded, default 30 s) → stop plugins → Gateway → Core; Compose `stop_grace_period` is set ≥ the sum of the bounds (default 45 s). Interrupted attempts follow the recovery rules in ARCHITECTURE §5.3.
- Health states `UNKNOWN`, `DEGRADED`, `UNRESPONSIVE`, `CRASH_LOOP` are distinct; a failed observation path never marks every component failed.
- Before a production release a **restore drill** recovers database metadata, media and credentials (with the separately held key).
- External publishing is not promised to be exactly-once where the provider cannot guarantee it; ambiguous results surface as `OUTCOME_UNKNOWN` and are not blindly retried.

## 2. Performance baseline

Single-installation baseline to validate, not a scale guarantee:

- 10 concurrent interactive users; 100 scheduled jobs pending; **5 concurrent publishing attempts** by default (configurable).
- Typical authenticated read request through BFF → Gateway → Core: **p95 < 500 ms** locally (excluding provider calls).
- Internal IPC overhead per hop (Gateway): **p95 < 20 ms** for small payloads over UDS; **< 100 ms** for web → Gateway over mTLS (local Compose).
- Health observation interval: 5 s default; an unhealthy transition requires several consecutive failures (default 3).
- Upload limit configurable; default **100 MiB** per media item, further bounded by provider rules. Chunked streaming (64 KiB); memory use independent of file size.
- Every queue, request body, upload, concurrent task and plugin storage quota is bounded.
- Default resource envelope (tunable): `server` 1 GiB memory / 512 pids; `web` 512 MiB / 128 pids; per-plugin memory per manifest (default 256 MiB).

## 3. Security

- Only the web entry point is published; default bind `127.0.0.1`; `production` mode refuses to run without mTLS between web and server.
- Cookie-authenticated mutations apply CSRF/origin protection and secure cookie settings.
- No plugin has database credentials, key material, or Docker access; **a plugin UID cannot read any secret file, Core state, the media volume, or another UID's `/proc` entries** (acceptance test).
- No container receives the Docker socket. Containers run with dropped capabilities and `no-new-privileges`; the server's Watchdog keeps only the minimal capability set documented in ADR-0004.
- Secrets are encrypted at rest and excluded from logs; passwords hashed with Argon2id.
- All sensitive operations have authorization tests; all IPC calls validate caller identity, capability, call token (for plugins), payload and deadline.
- Database migrations and plugin packages are versioned, checksummed and traceable; plugin executables are hash-pinned.
- Dependencies and release images are scanned before production releases; SBOM generated.
- C++ components build with warnings-as-errors, run under ASan/UBSan (and TSan where applicable) in CI, and are covered by static analysis.

## 4. Observability

- Structured JSON logs with timestamp, process/service, severity, request/correlation ID and event type. Each process logs to stdout; the Watchdog captures plugin stdout/stderr and tags it with the plugin ID.
- Logs redact credentials, cookies, tokens, call tokens, keys and sensitive content **by construction** (typed secret wrappers that cannot be printed), with pattern-based redaction as a second layer.
- Publishing attempts record job ID, attempt ID, plugin, outcome class, timing and external reference.
- Health status records last successful observation, consecutive failures, startup time, restart count and failure history per process.
- Audit events record actor, action, target, outcome and timestamp; credential leases are audited; secret values and full tokens are never included.
- Default retention (configurable): 14 days application logs, 90 days audit/job history, with disk-use safeguards.

## 5. Data integrity and migrations

- Every persistent entity has a stable internal ID; all timestamps in UTC; user scheduling time zone stored as IANA name.
- Constraints enforce essential invariants (ownership foreign keys, state enums, unique idempotency keys).
- Migrations are ordered, checksummed, run under an advisory lock, one transaction each, tested from an empty database **and** from the previous release.
- Destructive migrations require backup and recovery instructions.
- Backup scope: PostgreSQL data **and** media volume (consistent point in time). The **master key is backed up separately** from database backups, and restore documentation states that encrypted credentials are unrecoverable without it. Plugin packages are reproducible from the release bundle.

## 6. Portability and operations

- Docker Compose on a single Linux host is the supported target; other platforms only after smoke testing.
- Configuration is environment/file based with safe defaults; development, test and production configurations are distinct.
- Production images use exact versions/digests, never `latest`.
- A release bundle contains compatible `web`, `server` (watchdog/gateway/core), the contract version (`proto/` at the same deploy-repo tag), plugin API range, bundled plugin versions and migration notes.
- Host prerequisites are documented (kernel features optionally used for plugin hardening: Landlock, seccomp; rootful vs. rootless Docker behavior for secret file permissions).

## 7. Maintainability

- Process boundaries are used where trust or failure isolation requires them; inside a process, modules have defined interfaces without IPC.
- Unit tests for domain logic; integration tests with PostgreSQL and process interactions; contract tests for every service pair; SDK harness tests for plugins.
- Main branch remains deployable; CI blocks merges on failing tests, lint, sanitizers or `buf breaking`.
- New capabilities require updated feature list, contract, tests and roadmap status; boundary or trust changes require an ADR.
