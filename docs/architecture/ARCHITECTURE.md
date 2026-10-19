# Architecture Overview

**Status:** Proposed baseline. This document deliberately distinguishes logical responsibilities from process/container boundaries.

## 1. Deployment topology

One customer installation is one Docker Compose project. The intended logical services are:

1. **Web** — the browser-facing web application: frontend delivery plus a thin Backend-for-Frontend (BFF) for HTTP routes, cookie/session handling and typed request forwarding. It must not access PostgreSQL directly or own business authorization.
2. **Core** — business logic, authentication/authorization, application data access, plugin registry, secret broker, job manager, migrations and audit events.
3. **IPC Gateway** — authenticated internal request/response routing between Web, Core, Watchdog and plugin backends. It validates envelopes and enforces transport-level limits; it does not replace Core authorization.
4. **Watchdog** — independently observes health/readiness and reports lifecycle state. It does not have unrestricted access to the Docker socket.
5. **PostgreSQL** — private database service, not published to the host by default.
6. **Plugin runtime(s)** — plugin backend processes isolated from Core, preferably in dedicated containers with reduced privileges and bounded resources.

A future **Runtime Controller** may be introduced if UI-driven plugin installation must create containers dynamically. It is not part of the initial privileged surface. Do not mount `/var/run/docker.sock` into Web, Core, Watchdog or plugin containers. Docker's documentation warns that control of the daemon can grant broad host-level power; if dynamic runtime control is eventually needed, design a narrowly scoped privileged interface and threat-model it separately ([Docker Engine security](https://docs.docker.com/engine/security/)).

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

- Poll independent health endpoints and/or consume authenticated heartbeats.
- Track `STARTING`, `HEALTHY`, `DEGRADED`, `UNRESPONSIVE`, `STOPPED` and `UNKNOWN`.
- Distinguish a failed process from a failed health-check path.
- Track last success, consecutive failures, startup duration and failure history.
- Report health to the admin interface through a read-only, authenticated interface.
- Do not restart arbitrary containers directly in v1. Docker restart policies are the initial lifecycle owner; application-level recovery is handled by the responsible service. This avoids giving a monitoring service host-level control.
- Its own failure must not mark every monitored service unhealthy; its health must be visible to Docker/operator monitoring.

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

Separate containers are justified for Web, Core, Gateway, Watchdog, PostgreSQL and plugin runtimes because they have distinct trust/operational boundaries. This does not justify splitting every Core module into a service. Job Manager, Secret Broker, Plugin Registry, Authorization and Data Access are modules inside Core in v1.

The Gateway is a separate process by design, but should remain thin. Its availability is a dependency; Web/Core/plugin clients need bounded timeouts and clear failure responses. Watchdog must probe the Gateway and Core independently, not infer their health solely through the Gateway. The Web BFF is also thin: it owns browser/HTTP concerns, not domain logic or authoritative authorization.

## 8. Startup and shutdown

- Compose starts PostgreSQL and waits for database readiness.
- Core waits for database readiness and completes migrations before reporting ready.
- Gateway starts and exposes readiness only when its routing configuration is valid.
- Web becomes ready when it can serve the UI and its BFF endpoints; it may show a clear degraded service screen if Gateway/Core is unavailable. Readiness should distinguish “can serve UI” from “application operations are available.”
- Plugin runtimes report startup readiness and declared plugin/API compatibility.
- Watchdog marks dependencies as `UNKNOWN` until it has a successful observation; missing observations are not proof that every service is dead.
- Shutdown stops accepting new publishing work, persists/updates job claims, allows bounded in-flight completion, then exits.
