# ADR-0001: System Boundaries and Deployment Model

- **Status:** Proposed
- **Date:** 2026-10-19

## Context

PostFlowX is a self-hosted publishing platform that must support multiple users per installation, sensitive social tokens, scheduled jobs and plugins developed beyond the Core team. The project is starting from scratch, so architecture must balance future extensibility against implementation cost.

## Decisions

1. **One Compose deployment per customer.** The deploy repository owns the deployment manifest and pins compatible component versions.
2. **Web replaces the standalone client.** Web is the frontend plus a thin BFF for browser-facing HTTP/session concerns. It never connects directly to PostgreSQL and does not own domain authorization (see ADR-0002).
3. **Core owns business logic and authorization.** Authentication, ownership, secret access, plugin permissions, jobs and data access are enforced in Core.
4. **IPC Gateway is a separate, thin process.** It routes authenticated, versioned internal requests. It does not make authorization decisions on behalf of Core.
5. **Watchdog is a separate monitoring process.** It observes health independently and reports state. Docker restart policies are the initial container lifecycle mechanism; Watchdog does not receive unrestricted Docker control.
6. **Plugin backend code runs outside Core.** A plugin cannot load arbitrary code into Core or receive database credentials.
7. **PostgreSQL is private.** Only Core and explicit operational migration/backup paths can access it.
8. **Local persistent media storage is the MVP default.** A storage interface preserves the option to add S3-compatible storage later.
9. **No dynamic Docker control in the Core.** No application container receives the Docker socket. UI-driven dynamic container creation is deferred until a narrowly scoped Runtime Controller is designed and threat-modeled.
10. **Application admin is not database superuser.** Administrative permissions are application-level; database superuser access is an operator break-glass path.
11. **No arbitrary plugin SQL.** Plugins use typed Core APIs and controlled migrations.
12. **Plugin data layout uses one schema per plugin installation.** Per-user ownership is represented in records and checked by Core; no schema-per-user explosion in v1.
13. **Instagram first; AI text generation later; TikTok later.** External API capabilities and permissions must be revalidated before each integration release.

## Consequences

- Gateway availability becomes a dependency, so timeouts and degraded states are mandatory.
- Third-party plugin isolation and installation are intentionally staged; a public plugin marketplace is not an MVP feature.
- One schema per plugin installation limits namespace collisions and keeps migrations manageable; it is not considered sufficient isolation by itself.
- The deployment bundle and compatibility matrix become release-critical artifacts.
- Additional process boundaries must be justified by a trust, deployment or failure-isolation need, not by code organization alone.

## Alternatives considered

- Put all logic in one process: simpler, but weakens the intended plugin isolation and service contracts.
- Give plugins direct PostgreSQL access: rejected due to excessive data exposure and bypass of Core authorization.
- Let Core mount the Docker socket to create plugin containers: rejected because it creates a highly privileged control path in the main application.
- Build a bespoke process supervisor immediately: deferred; Docker already handles container lifecycle in the initial deployment.
