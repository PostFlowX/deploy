# Architecture Overview

**Status:** Proposed baseline. This document deliberately distinguishes logical responsibilities from process/container boundaries.

## 1. Deployment topology

One customer installation is one Docker Compose project. The intended initial container/process boundaries are:

1. **Web (`postflowx-web`)** — a separate container for frontend delivery and the thin browser-facing BFF. It handles HTTP routes, cookie/session transport, browser protections and typed request forwarding. It must not access PostgreSQL directly or own business authorization.
2. **Server (`postflowx-server`)** — a separate container running one primary server process. The **Core**, **IPC Gateway**, and **Watchdog** are internal modules in this process, not separate containers or operating-system processes in the initial architecture.
3. **PostgreSQL** — a private database container with persistent storage. Only the server's approved data-access layer receives application database credentials; explicitly authorized operational backup/restore paths are documented separately.
4. **Plugin runtime(s)** — plugin backend code runs outside the server process in an isolated execution environment, preferably in dedicated containers with reduced privileges and bounded resources. The exact provisioning and container granularity are finalized in the plugin-runtime milestones.

Docker Compose/container runtime configuration owns container startup, shutdown and restart policies. The Watchdog observes and reports health but does not receive unrestricted Docker control. A future Runtime Controller for dynamic plugin provisioning is not part of the initial privileged surface; it requires a separate narrow interface and threat model.

### Initial technology baseline

- Server: C++20.
- Web BFF: TypeScript + Fastify.
- Frontend: TypeScript + React + Vite.
- Preferred typed internal RPC contract: gRPC + Protocol Buffers, pending validation in M0.3.
- Database: PostgreSQL.
- Deployment: Docker Compose.

The PostgreSQL client library, build/dependency tooling, transport authentication and detailed plugin isolation mechanism remain open implementation decisions for their assigned milestones. PostAPI source review is deferred until Instagram plugin implementation.

## 2. Trust boundaries

- Browser ↔ Web BFF: untrusted client; validate all input server-side, apply browser-facing protections (including CSRF protection for cookie-authenticated mutations), and never treat client-supplied identity as authoritative.
- Web BFF ↔ IPC Gateway ↔ Core: authenticated internal service calls. The BFF carries the verified session context using the agreed internal contract; Core validates the context and makes the final authorization decision. Never trust user identity supplied only in a request body.
- Plugin UI ↔ main application: separate execution context; strict message allowlist.
- Plugin backend ↔ IPC Gateway/Core: plugin identity plus scoped user context and capability checks.
- Core ↔ PostgreSQL: privileged data access; parameterized queries, fixed/validated identifiers, least-privileged database roles.
- Deployment operator ↔ host/Compose/secrets: high-trust operational boundary.

## 3. Responsibilities

### Web (frontend + thin Backend-for-Frontend)

- Serve the frontend, browser-facing routes and a small set of typed HTTP/API endpoints used by the UI.
- Handle cookie parsing, session transport and browser-facing protections; Core remains authoritative for session validity, identity, roles, ownership and authorization. The precise cookie/session mechanism is an open decision.
- Forward application operations through the IPC Gateway; do not duplicate domain/business logic or make final permission decisions.
- Normalize browser-facing errors and response shapes without leaking internal details.
- Never store platform access tokens or long-lived bearer tokens in browser local storage or URLs.
- Never connect to PostgreSQL.
- Render plugin navigation from authorized registry metadata.
- Load plugin UI in a restricted frame/origin; expose only a documented, narrow message bridge.

### Core

- Single source of truth for business authorization and ownership.
- Own user/session records, plugin registry, publishing jobs, audit events and media metadata.
- Validate all plugin requests against manifest capabilities and current user grants.
- Broker data access and secrets; never expose DB credentials to plugins.
- Own scheduling, retry decisions and job state transitions.
- Apply versioned database migrations.
- Emit health/readiness and structured diagnostic information.

### IPC Gateway

- Provide a versioned internal protocol and route messages to allowed services.
- Authenticate service identities; reject unknown identities, invalid envelopes and unsupported protocol versions.
- Apply request-size limits, deadlines, rate/concurrency limits and correlation IDs.
- Do not grant permissions based solely on a message's claimed plugin/user ID.
- Do not expose internal routes publicly.

### Watchdog

- Run as an internal module in the server process and use explicit interfaces to observe internal module state and authorized dependency health.
- Track `STARTING`, `HEALTHY`, `DEGRADED`, `UNRESPONSIVE`, `STOPPED` and `UNKNOWN` where the monitored target can report those states.
- Distinguish a failed dependency/health-check path from a failed server process. The Watchdog cannot continue observing the server after the entire process terminates; Docker/operator monitoring owns that boundary.
- Track last success, consecutive failures, startup duration and failure history.
- Report health to the admin interface through a read-only, authenticated interface.
- Do not restart arbitrary containers directly in v1. Docker restart policies are the initial lifecycle owner; application-level recovery is handled by the responsible service. This avoids giving a monitoring service host-level control.
- An internal Watchdog failure must not mark every monitored service unhealthy; server-process health remains visible to Docker/operator monitoring.

### PostgreSQL

- Persist application state, job state and metadata.
- Be reachable only from the Core and explicitly authorized migration/backup paths.
- Use explicit roles and grants; revoke unnecessary `CREATE` rights in `public`; use safe schema qualification and a reviewed `search_path`.
- Never treat schema names as authorization by themselves. PostgreSQL documents that schemas are not rigidly separated unless privileges are configured correctly; use explicit grants and a reviewed `search_path` (see [PostgreSQL schema documentation](https://www.postgresql.org/docs/18/ddl-schemas.html)).

### Plugin runtime

- Runs outside Core and receives only the capabilities it needs.
- Has no database credentials, Docker socket, host filesystem mounts or ambient administrative token.
- Uses a dedicated service identity; a user-scoped request includes an authenticated actor/context established by Core, not one trusted solely from plugin input.
- Has bounded CPU/memory, timeouts, restricted filesystem, dropped capabilities and controlled network access where feasible.
- Is considered untrusted unless explicitly installed and trusted by the deployment operator. Isolation reduces risk; it does not guarantee perfect containment.

## 4. Communication flow

### Browser request

1. Browser sends a request to the Web BFF.
2. The BFF applies browser-facing validation and protections, then forwards a typed request through the Gateway with session context established by the agreed authentication flow.
3. Core validates that context, derives the actor, checks authorization/ownership, executes the operation and returns a typed result.
4. Gateway routes the response; the BFF maps it to a safe browser-facing response.

### Plugin request

1. Plugin backend authenticates with its own service identity.
2. It requests a capability-defined operation through the Gateway.
3. Core verifies plugin identity, installed version, grant, user scope, resource ownership and input schema.
4. Core performs the operation and returns only the minimum necessary result.
5. The plugin cannot bypass Core by querying PostgreSQL.

### Scheduled publication

1. Core creates a durable job and stores its state.
2. The Core job manager claims due jobs with concurrency limits and a lease/claim mechanism.
3. The integration plugin performs the external API operation.
4. The result is recorded with an attempt ID and external platform identifiers when available.
5. On ambiguous outcomes, Core marks the job `OUTCOME_UNKNOWN` for reconciliation rather than blindly retrying and risking duplicate publication.

## 5. Database organization

- Core-owned tables: users, sessions, roles/grants, plugin registry, plugin installations/instances, jobs, job attempts, media metadata, audit events and migration state.
- Use one schema per installed plugin (or plugin installation), with per-user ownership represented in records where needed. Core validates the owner scope on every operation. Do not create one schema per user/plugin pair in v1: it multiplies migration state and operational complexity without creating a security boundary when Core owns the database connection.
- Core maps immutable internal IDs to schema identifiers. Never interpolate unchecked plugin/user names into SQL identifiers.
- Plugin code cannot submit arbitrary SQL. Plugin data access uses typed storage operations and a controlled migration mechanism.
- Migrations are versioned, reviewed, transactional where supported, and have explicit rollback/forward-recovery policy.
- Admin UI access is application-level; raw database superuser credentials are not part of the product.

## 6. Media storage

MVP uses a persistent local volume behind a `MediaStorage` interface. PostgreSQL stores metadata and references, not large binary media payloads. Uploads use generated object IDs, strict size/type checks, temporary staging, safe file permissions and cleanup rules. The interface leaves room for S3-compatible storage later without making it a launch blocker.

## 7. Process boundaries and scope control

Separate containers are used for Web, the combined Server process, PostgreSQL and isolated plugin runtime(s). Core, Gateway and Watchdog are modules within the server process in the initial architecture. Job Manager, Secret Broker, Plugin Registry, Authorization and Data Access are modules inside Core in v1.

The Gateway is an internal module in the server process, but its interface remains a logical contract. Web/plugin clients need bounded timeouts and clear failure responses. The Watchdog observes internal module health through explicit interfaces and must not be treated as an independent process monitor. Health reporting must distinguish Core/Gateway module failures where possible, rather than inferring all health solely from one end-to-end Gateway request. The Web BFF remains thin and owns browser/HTTP concerns, not domain logic or authoritative authorization.

## 8. Startup and shutdown

- Compose starts PostgreSQL and waits for database readiness.
- Core waits for database readiness and completes migrations before the server reports application readiness.
- The Gateway module becomes ready only when its routing configuration and service handlers are valid.
- Web becomes ready when it can serve the UI and its BFF endpoints; it may show a clear degraded service screen if Gateway/Core is unavailable. Readiness should distinguish “can serve UI” from “application operations are available.”
- Plugin runtimes report startup readiness and declared plugin/API compatibility.
- Watchdog marks dependencies as `UNKNOWN` until it has a successful observation; missing observations are not proof that every service is dead.
- Shutdown stops accepting new publishing work, persists/updates job claims, allows bounded in-flight completion, then exits.
