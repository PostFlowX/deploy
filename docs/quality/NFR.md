# Non-Functional Requirements

**Status:** Initial measurable targets. Treat values as proposed baselines and adjust only with an ADR and corresponding tests.

## 1. Reliability and recovery

- The Compose stack must start from a clean installation using documented steps without hidden manual setup.
- Core must not report ready until required database migrations have completed successfully.
- A process restart must not erase queued publishing jobs or attempt history.
- A graceful shutdown should stop claiming new jobs and persist claim/attempt state before exit.
- Health checks distinguish `UNKNOWN`, `DEGRADED` and `UNRESPONSIVE`; a failed monitoring path must not mark every service failed.
- Before production release, a restore drill must recover both database metadata and media references from backup.
- External publishing is not promised to be exactly-once where the platform API cannot guarantee it; ambiguous results are surfaced rather than blindly retried.

## 2. Performance baseline

Initial single-installation baseline to validate, not a scale guarantee:

- 10 concurrent interactive users.
- 100 scheduled jobs pending.
- 5 concurrent publishing jobs maximum by default, configurable downward/upward within resource limits.
- Typical authenticated read request: p95 under 500 ms in a local test environment, excluding external platform calls.
- Internal IPC request overhead: p95 under 100 ms for small payloads in the local Compose environment, excluding database-heavy work.
- Health observation interval: 5 seconds default; unhealthy threshold requires multiple consecutive failures to avoid transient false positives.
- Upload size limit configurable; initial default 100 MiB per media item, subject to platform-specific limits and deployment resources.
- Every queue, request body, upload and concurrent task has a bounded limit.

These targets must be measured in CI/integration or a documented benchmark environment before being treated as achieved.

## 3. Security

- Only the Web BFF/public entry point is exposed to the host by default; Gateway, Core, PostgreSQL and plugin runtimes stay private.
- Cookie-authenticated state-changing routes apply CSRF/origin protections and secure cookie settings.
- No plugin has direct database access.
- No application container has the Docker socket in v1.
- Services run as non-root where practical.
- Secrets are encrypted at rest and excluded from logs.
- All sensitive endpoints have authorization tests.
- All IPC calls validate identity, capability, payload and deadline.
- Database migrations and plugin packages are versioned and traceable.
- Dependencies and release images are scanned before production releases.

## 4. Observability

- Structured logs include timestamp, service, severity, request/correlation ID and event type.
- Logs redact credentials, cookies, tokens, encryption keys and sensitive content.
- Publishing attempts record job ID, attempt ID, outcome class, timing and external reference when available.
- Health status records last successful observation, consecutive failures, startup time and recent failure history.
- Audit events record actor, action, target, outcome and timestamp; secret values and full access tokens are never included.
- Default log retention is configurable; proposed initial retention is 14 days for application logs and 90 days for audit/job history, with disk-use safeguards.

## 5. Data integrity and migrations

- Every persistent entity has a stable internal ID.
- All timestamps are stored in UTC; user scheduling timezone is stored explicitly.
- Database constraints enforce essential invariants where possible.
- Migrations are ordered, versioned and tested from both empty and previous-release databases.
- Destructive migrations require backup and recovery instructions.
- Plugin migrations are associated with plugin installation/version and cannot silently run for an incompatible plugin.
- Backups include PostgreSQL data and media objects; key material is handled according to a documented separate-secret backup policy.

## 6. Portability and operations

- Docker Compose is the supported initial deployment target.
- Linux host is the initial reference platform; other platforms are supported only after smoke testing.
- Configuration is environment/file based and documented with safe defaults.
- Development, test and production configurations are distinct.
- Production images use explicit versions/digests rather than floating `latest`.
- A release includes compatible Web/Core/Gateway/Watchdog/plugin versions and migration notes.

## 7. Maintainability

- Core modules have defined interfaces; only actual process boundaries use IPC.
- Unit tests cover domain logic; integration tests cover PostgreSQL and service interactions; contract tests cover IPC/plugin compatibility.
- Main branch remains deployable.
- New capabilities require updated feature list, API contract, tests and roadmap status.
- Architecture decisions are recorded in ADRs rather than silently encoded in implementation.
