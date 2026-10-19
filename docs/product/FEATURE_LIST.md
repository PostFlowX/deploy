# Feature List

Priorities: **P0** required foundation / MVP blocker; **P1** MVP capability; **P2** later enhancement; **P3** optional/future. Status is planning-only.

## A. Deployment and operations

- **P0** One documented Docker Compose deployment for the complete baseline stack.
- **P0** Separate Web, Core, IPC Gateway, Watchdog and PostgreSQL services; plugin runtimes are isolated from Core.
- **P0** Persistent PostgreSQL and media volumes.
- **P0** Internal services are not published to host interfaces by default.
- **P0** Health checks, readiness checks, structured logs and graceful shutdown.
- **P0** Version-pinned images and documented configuration/secrets.
- **P1** Backup and restore scripts with tested recovery instructions.
- **P1** Upgrade and rollback procedure, including database migration rules.
- **P2** Optional S3-compatible media storage behind a storage interface.

## B. Users, roles and authorization

- **P0** Authentication, secure sessions and logout.
- **P0** Installation administrator can create, disable and manage users.
- **P0** Role-based authorization enforced server-side.
- **P0** User ownership enforced on every account, content, job, plugin-instance and secret operation.
- **P0** Deny-by-default capability checks for plugin calls.
- **P0** Audit events for sensitive administrative and publishing actions.
- **P1** Explicitly delegated/shared resources between users, only if required by a defined use case.
- **Constraint** Application administrators do not get implicit database superuser access.

## C. Plugin system

- **P0** Versioned plugin manifest and documented compatibility rules.
- **P0** Plugin registry with status, version, requested/granted permissions and lifecycle state.
- **P0** Plugin backend runs outside the Core process.
- **P0** Plugins communicate with Core through authenticated IPC/API contracts.
- **P0** Plugins have no PostgreSQL credentials and no unrestricted SQL API.
- **P0** Core validates the authenticated caller, user scope, resource ownership and capability for every request.
- **P0** Plugin UI is isolated from the main application origin and receives no secret tokens.
- **P1** Reference plugin and minimal developer SDK.
- **P1** Explicit enable/disable and uninstall behavior, including data-retention choice.
- **P1** Plugin migrations are versioned, validated, and applied by a controlled Core migration mechanism.
- **P2** Signed packages, provenance verification, controlled updates and rollback.
- **P2** Public plugin catalog/marketplace.
- **Constraint** A plugin's manifest is a declaration, not proof that its code is safe.

## D. Data and secrets

- **P0** Core-owned schema for users, sessions, plugin registry, jobs, audit events and media metadata.
- **P0** Plugin data is namespaced by plugin identity and owner scope.
- **P0** No schema names or SQL identifiers are constructed from unchecked user/plugin input.
- **P0** Database roles are least-privileged; `public` schema privileges and `search_path` are explicitly reviewed.
- **P0** Credentials encrypted at rest; key material stored separately from ciphertext and excluded from database backups where practical.
- **P0** Only authorized Core code can request decryption; secrets are not returned to plugin UI or ordinary frontend code.
- **P0** Secret rotation and token revocation/expiry states are represented.
- **P1** Data export/deletion and clear uninstall retention semantics.
- **P1** Media upload validation, size limits, temporary-file cleanup and quota policy.

## E. Publishing and jobs

- **P0** Content draft and media metadata.
- **P0** Immediate publishing through the first supported integration.
- **P0** Scheduled publishing with timezone-aware timestamps.
- **P0** Persistent job state, attempt history, bounded retries and explicit terminal states.
- **P0** Idempotency keys and duplicate-prevention logic.
- **P0** Handle expired tokens, rate limits, transient errors and permanent API errors distinctly.
- **P0** Recover queued/running jobs after restart without blindly duplicating external posts.
- **P0** Treat ambiguous external outcomes as `OUTCOME_UNKNOWN` and require reconciliation before a risky retry.
- **P1** Job history, user-facing error explanations and admin diagnostics.
- **P2** Retry policy tuning and bulk operations.

## F. Web application

- **P0** Frontend plus thin Backend-for-Frontend (BFF) for browser-facing HTTP/API routes; not a static-server-only design and not a second domain backend.
- **P0** BFF forwards typed application operations through the IPC Gateway; no direct Web-to-PostgreSQL access.
- **P0** Browser session/cookie handling with CSRF/origin protections as appropriate; Core remains authoritative for identity, session validity and authorization.
- **P0** Main application shell, authentication views and navigation.
- **P0** Admin UI for users, plugins and health status.
- **P0** User UI for social accounts, content and jobs.
- **P0** Plugin navigation generated from authorized installed plugin metadata.
- **P0** Plugin UI runs in a restricted iframe or equivalent isolated origin with a narrow message bridge.
- **P1** Per-plugin settings and subpages.
- **P1** Accessible form validation, loading/error states and responsive layout.

## G. Social integrations and AI

- **P0** Instagram plugin is the first production integration, subject to current Meta API capabilities and app review/permissions.
- **P0** Reuse of existing PostAPI code only after audit, tests and separation of credentials/business logic.
- **P2** AI text-generation provider interface and user-visible generated-text review before publishing (later scope; not required for the first Instagram release).
- **P2** TikTok plugin after API feasibility, permissions and product requirements are verified.
- **P2** Additional providers and integrations.

## H. Reliability, security and quality

- **P0** Unit, integration, contract, authorization and deployment smoke tests.
- **P0** Independent Watchdog health observation; health monitoring must not depend solely on the IPC Gateway.
- **P0** Docker restart policy is the initial container lifecycle mechanism; Watchdog observes and reports rather than holding unrestricted Docker control.
- **P0** Crash-loop and repeated-failure detection with actionable status.
- **P0** Rate limits, request size limits, timeouts and bounded concurrency.
- **P0** Threat model and security acceptance tests.
- **P1** Dependency scanning, image scanning and release provenance.
- **P1** Performance/load tests with stated baseline workload.
