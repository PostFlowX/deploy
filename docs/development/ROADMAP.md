# Implementation Roadmap

**Principle:** one milestone at a time; each milestone has acceptance criteria and tests. Keep the main branch runnable. Avoid implementing downstream features against undocumented contracts.

## Dependency overview

```text
M0 Architecture/contracts
  └─ M1 Repositories + Compose skeleton
      └─ M2 Engineering foundation
          ├─ M3 IPC Gateway + protocol
          │   └─ M4 Core foundation + database access
          │       ├─ M5 Watchdog + health model (parallel after health contracts)
          │       └─ M6 Authentication + authorization
          │           ├─ M10 Web application/BFF shell can begin after the basic auth/API contract
          │           └─ M7 Plugin registry + permissions
          │               └─ M8 Plugin runtime + reference plugin
          │                   └─ M9 Data isolation + secrets + media
          │                       └─ M10 Web application integration/completion
          │                           └─ M11 Durable publishing jobs
          │                               └─ M12 Instagram integration
          │
          └─ M15 Deployment, backup, upgrade and operations (starts early; release acceptance later)

M11 + stable publishing/plugin contracts ──┬─ M13 AI text generation (later scope)
                                           └─ M14 TikTok feasibility/integration (external API gate)

M16 Security/reliability release gate depends on all release-critical milestones,
including M11, M12 and M15; M13/M14 are not blockers for the first Instagram release.
```

M10 is intentionally split in practice: build a minimal BFF/app shell early enough to exercise authentication and end-to-end contracts, then complete plugin, account, content and job views as their APIs stabilize. M13 and M14 are separate later workstreams, not sequential prerequisites for each other. M15 begins early but its production acceptance depends on the actual release candidate.

## M0 — Architecture and contracts

### M0.1 Component responsibilities

- Confirm Web BFF, Core, Gateway, Watchdog, PostgreSQL and plugin-runtime responsibilities.
- Decide which are separate containers and which are modules inside Core.
- Select the initial language/framework after reviewing reusable PostAPI code and the requirements for Web BFF, Core and service processes.
- Document trust boundaries and forbidden communication paths.
- **Accept when:** architecture and ADR agree; no component has overlapping ownership of authorization, job state or container lifecycle.

### M0.2 Lifecycle and failure model

- Define startup/readiness/degraded/shutdown states and dependency order.
- Define Gateway outage, database outage, plugin crash, Watchdog crash and interrupted job behavior.
- **Accept when:** every critical failure has an observable state and a safe response; Docker owns container restart policy in v1.

### M0.3 IPC contract

- Define envelope, identity, correlation ID, deadline, errors, versioning, idempotency and contract tests.
- Select initial transport.
- **Accept when:** sample Web BFF→Gateway→Core and plugin→Gateway→Core requests validate; malformed/unauthenticated/unsupported messages fail closed.

### M0.4 Plugin contract

- Define manifest, stable identity, requested/granted capabilities, frontend/backend entry points, lifecycle and compatibility.
- **Accept when:** reference plugin can be described without arbitrary SQL or implicit admin privileges.

### M0.5 Data, secret and operational contracts

- Define core entities, plugin data namespace, migrations, secret encryption/key handling, media storage, scheduling timezone policy and backup scope.
- **Accept when:** data flows and secret/key recovery are documented; schema names cannot come from unchecked input.

**Gate:** no implementation beyond disposable spikes until M0 decisions are recorded.

## M1 — Repository and Docker foundation

### M1.1 Repository boundaries

- `postflowx-web`: frontend plus thin BFF (browser-facing HTTP/API, cookie/session transport, CSRF/origin protections, typed forwarding through Gateway). No domain authorization or direct database access.
- `postflowx-server`: Core, Gateway, Watchdog and plugin runtime images/modules, separated by explicit entry points.
- `postflowx-deploy`: Compose files, sample environment, health checks and deployment docs.
- **Accept when:** responsibilities and versioning policy are documented; no secrets committed.

### M1.2 Compose skeleton

- Private networks, named volumes, service dependencies and health checks.
- **Accept when:** fresh clone can build/start the minimal stack.

### M1.3 Minimal service containers

- Web BFF, Core, Gateway and Watchdog return health/readiness status; Web distinguishes UI availability from application-operation availability.
- PostgreSQL readiness and persistent volume are configured.
- **Accept when:** restart preserves database state; only intended public port is exposed.

### M1.4 End-to-end smoke test

- Browser reaches Web BFF; BFF reaches Gateway/Core; Core reaches PostgreSQL; Watchdog probes Gateway/Core independently.
- **Accept when:** automated test verifies expected healthy and unavailable states.

## M2 — Engineering foundation

- Formatting/linting, unit tests, integration test environment, CI, structured logs, configuration validation and error handling.
- Build reproducible development images and pin base images.
- **Accept when:** CI runs on every change and failures block merge; logs redact known secret patterns.

## M3 — IPC Gateway and protocol

- Implement protocol v1, service authentication, route allowlist, payload validation, deadlines, size limits, correlation IDs and stable errors.
- No public Gateway port.
- **Accept when:** contract tests cover valid, invalid, expired, forbidden and unsupported-version requests; Gateway cannot bypass Core authorization.

## M4 — Core foundation

- Core module boundaries, database layer, migration runner, request dispatcher, audit event model and readiness checks.
- Add core-owned schema for users, plugin registry, jobs, media metadata and audit.
- **Accept when:** migrations work from an empty database; DB errors are not leaked to clients; no Web/plugin direct DB connection exists.

## M5 — Health model and Watchdog

- Implement independent observations, lifecycle states, startup timeout, repeated-failure detection and admin-visible health model.
- Monitor Web, Core, Gateway, PostgreSQL and plugin runtimes; monitor Watchdog itself via container/operator health.
- **Accept when:** Gateway outage is distinguishable from Core outage; Watchdog failure does not mark every service dead; Docker restart behavior is documented/tested.

## M6 — Authentication and authorization

- Login/logout, secure sessions, user administration, role grants and resource ownership enforcement.
- Add cross-user and privilege-escalation tests.
- **Accept when:** unauthorized access fails server-side for every protected resource; no client-provided user ID can override authenticated identity.

## M7 — Plugin registry and capability grants

- Manifest parser, compatibility checks, install registry, enable/disable state, permission review and lifecycle state machine.
- Only allow controlled/bundled plugin packages at this stage.
- **Accept when:** incompatible/invalid plugins cannot activate; capability changes are auditable; no public remote installer exists.

## M8 — Plugin runtime and reference plugin

- Run backend outside Core; implement authenticated service identity and minimal SDK.
- Implement isolated frontend frame and narrow message bridge.
- Do not expose DB or Docker socket.
- **Accept when:** reference plugin can read/write only its permitted scope; crash and malformed calls are handled; plugin UI cannot access main app secrets.

## M9 — Data isolation, secrets and media

- Plugin-scoped storage API and controlled migrations.
- Authenticated encryption for tokens; key sourced outside DB; redact secrets.
- Local persistent media storage abstraction, upload validation and cleanup.
- **Accept when:** backup contains ciphertext but not the encryption key; restore instructions account for key; cross-plugin/user data tests pass.

## M10 — Web application and BFF

- Implement browser-facing HTTP/API routes, secure session/cookie transport, CSRF/origin protections, typed Gateway forwarding and safe error mapping.
- Deliver authenticated app shell, user pages, admin pages, plugin navigation, accounts/content/job views and accessible error/loading states.
- Keep the BFF thin: no direct PostgreSQL access and no duplicated business rules or authoritative authorization.
- **Accept when:** UI only shows authorized plugins/resources; all actions are reauthorized in Core; no token is stored in browser local storage or URL.

## M11 — Durable publishing jobs

- Persistent state machine, claim/lease semantics, concurrency limits, attempt history, timezone-aware scheduling, bounded retries and `OUTCOME_UNKNOWN`.
- Test DST, missed schedules, token expiry, rate limit, process restart and external timeout cases.
- **Accept when:** no job disappears on restart; ambiguous external outcomes are not blindly retried; duplicate prevention is tested.

## M12 — Instagram integration

- Audit/reuse existing PostAPI logic; separate API client, account/token lifecycle, media handling, platform errors and publishing operations.
- Verify current Meta API requirements and account eligibility before coding.
- **Accept when:** supported immediate and scheduled posts work in a test environment; token expiry/revocation and external failure paths are tested; no credentials leak to UI/logs.

## M13 — AI text generation

- Provider interface, configuration, timeout/rate/cost controls, generated-text review/edit step and audit of provider outcome without logging secrets.
- **Accept when:** user can review/edit before publishing; provider failure does not block manual publishing.

## M14 — TikTok feasibility and integration

- First confirm current API, app permissions, supported account types and media requirements.
- Implement only supported operations through plugin contract.
- **Accept when:** documented API feasibility exists before work starts; tests cover supported publish and error states.

## M15 — Deployment and operations

- Backup/restore, upgrade/rollback, environment validation, version compatibility matrix, resource limits, logging/retention and troubleshooting docs.
- **Accept when:** clean install, upgrade and restore drills pass on the supported reference host.

## M16 — Security and release gate

- Threat-model review, dependency/image scan, authorization/IPC/plugin isolation tests, load test, failure injection and user documentation.
- **Accept when:** all P0 acceptance criteria pass; known residual risks are documented; release bundle is version-pinned and reproducible.

## Critical path

The release critical path is M0 → M1 → M2 → M3 → M4 → M6 → M7 → M8 → M9 plus M10 integration → M11 → M12 → M15/M16. M10’s basic BFF/app shell can start earlier once the initial auth and IPC contracts are stable.

M5 can progress alongside M4 after health contracts stabilize. M15 starts early and proceeds in parallel, but its release acceptance is required before M16. AI and TikTok are not prerequisites for the first Instagram release and may proceed independently after the publishing/plugin contracts stabilize; TikTok is gated by external API feasibility. Do not let future plugin marketplace work block the first controlled reference plugin.

## Working rules

1. One milestone at a time, with small reviewable tasks.
2. Add tests with the feature, not at the end.
3. Keep main deployable; do not leave hidden manual steps.
4. Backend authorization is authoritative.
5. Every persistent state transition has a defined failure path.
6. Update feature status and this roadmap after acceptance.
7. Any change to a boundary or security assumption requires an ADR and review of dependent docs.
