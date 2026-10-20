# ADR-0001: System Boundaries and Deployment Model

- **Status:** Proposed baseline; updated component/process boundaries
- **Date:** 2026-10-19

## Context

PostFlowX is a self-hosted publishing platform that must support multiple users per installation, sensitive social tokens, scheduled jobs and plugins developed beyond the Core team. The project is starting from scratch, so architecture must balance future extensibility against implementation cost.

## Decisions

1. **One Compose deployment per customer.** The deploy repository owns the deployment manifest and pins compatible component versions.
2. **Web replaces the standalone client.** Web is the frontend plus a thin BFF for browser-facing HTTP/session concerns. It never connects directly to PostgreSQL and does not own domain authorization (see ADR-0002).
3. **Core owns business logic and authorization.** Authentication, ownership, secret access, plugin permissions, jobs and data access are enforced in Core.
4. **IPC Gateway is an internal server module.** It runs in the `postflowx-server` process and routes authenticated, versioned internal requests through explicit interfaces. It does not make authorization decisions on behalf of Core.
5. **Watchdog is an internal server module.** It receives permitted instructions through Core-defined interfaces, observes internal module/dependency health and reports state through defined interfaces. It cannot observe the server after the entire server process terminates. Docker/operator health monitoring handles process-level failure. Docker restart policies are the initial container lifecycle mechanism; Watchdog does not receive Docker lifecycle access.
6. **Plugin backend code runs outside Core.** A plugin cannot load arbitrary code into Core or receive database credentials.
7. **PostgreSQL is private.** Only Core and explicit operational migration/backup paths can access it.
8. **Local persistent media storage is the MVP default.** A storage interface preserves the option to add S3-compatible storage later.
9. **No dynamic Docker control in the Core.** No application container receives the Docker socket. UI-driven dynamic container creation is deferred until a narrowly scoped Runtime Controller is designed and threat-modeled.
10. **Application admin is not database superuser.** Administrative permissions are application-level; database superuser access is an operator break-glass path.
11. **No arbitrary plugin SQL.** Plugins use typed Core APIs and controlled migrations.
12. **Plugin data layout uses one schema per plugin installation.** Per-user ownership is represented in records and checked by Core; no schema-per-user explosion in v1.
13. **Instagram first; AI text generation later; TikTok later.** External API capabilities and permissions must be revalidated before each integration release.
14. **Initial technology baseline:** C++20 for the server, gRPC + Protocol Buffers as the preferred typed IPC contract (transport validated in M0.3), TypeScript + Fastify for the Web BFF, and TypeScript + React + Vite for the frontend. PostgreSQL and Docker Compose remain the initial database/deployment choices. Detailed dependencies remain assigned to later milestones.
15. **PostAPI reuse is deferred.** PostAPI source review is performed during Instagram plugin implementation (M12), not as a prerequisite for the platform architecture or initial language selection.

## Consequences

- The server is a single process boundary for Core, Gateway and Watchdog in the initial architecture; internal module health must be observable, while process-level health is monitored externally.
- The Web BFF and server use a typed, versioned communication contract; the transport implementation is validated in M0.3.
- Gateway/interface failures still require bounded timeouts and clear degraded-state behavior.
- Third-party plugin isolation and installation are intentionally staged; a public plugin marketplace is not an MVP feature.
- One schema per plugin installation limits namespace collisions and keeps migrations manageable; it is not considered sufficient isolation by itself.
- The deployment bundle and compatibility matrix become release-critical artifacts.
- Additional process boundaries must be justified by a trust, deployment or failure-isolation need, not by code organization alone.

## Alternatives considered

- Separate Core, Gateway and Watchdog processes: deferred for the initial release because they do not currently require independent deployment; logical interfaces preserve module boundaries.
- Put all logic and plugin code in one process: rejected because it weakens plugin isolation and service contracts.
- Give plugins direct PostgreSQL access: rejected due to excessive data exposure and bypass of Core authorization.
- Let Core mount the Docker socket to create plugin containers: rejected because it creates a highly privileged control path in the main application.
- Build a bespoke process supervisor immediately: deferred; Docker already handles container lifecycle in the initial deployment.
