# ADR-0001: System Boundaries and Deployment Model

- **Status:** Proposed baseline — **revision 2** (2026-10-22)
- **Date:** 2026-10-19 (revised 2026-10-22)
- **Related:** ADR-0002 (Web/BFF), ADR-0003 (stack), ADR-0004 (server container, watchdog, plugin hosting), ADR-0005 (plugin data, credentials, UI, publishing contract)

## Context

PostFlowX is a self-hosted publishing platform: one Docker Compose stack per customer installation, multiple users, sensitive social tokens, scheduled jobs, and platform functionality delivered by plugins. The first goal is to get the **infrastructure** running end to end; the Instagram plugin is built afterwards in a separate repository against the plugin contract.

Revision 2 replaces the earlier "Core, Gateway and Watchdog are modules of one process" model with a **multi-process server container**, and replaces "plugins run in separate, restricted containers" with **plugins as separate OS processes inside the server container**. Rationale and consequences are in ADR-0004.

## Decisions

1. **One Compose project per customer.** The deploy repository owns the Compose manifest and pins compatible component versions.
2. **Three application containers:** `web`, `server`, `db`. An optional TLS reverse proxy (`proxy`, profile `tls`) may be added. No other containers in v1.
3. **`web` = frontend + thin BFF** (ADR-0002). It never connects to PostgreSQL and owns no domain authorization.
4. **`server` is one container with several OS processes** (details: ADR-0004):
   - **Watchdog** (PID 1, supervisor + health observer),
   - **IPC Gateway** (the only router and the only place where caller identity is assigned),
   - **Core** (business logic, authorization, jobs, secrets, the only database client),
   - **Plugin processes** (one per enabled plugin).
   They communicate with each other via **gRPC over Unix domain sockets**; each process runs under its own UID.
5. **Web ↔ server uses gRPC over TCP with mutual TLS** on the private `backend` network.
6. **Core owns authorization, ownership, secrets, jobs and all database access.** The Gateway routes and limits; it does not decide authorization.
7. **Plugins are native executables** started by the Watchdog as child processes of the server container. They have no database credentials, no key material and no Docker access; they obtain everything through typed Core APIs (ADR-0005).
8. **Plugin trust model v1:** only *bundled* or *operator-approved* plugins run. Untrusted third-party code is **not supported** in v1. The in-container model is process isolation, not a sandbox for hostile code (ADR-0004, THREAT_MODEL).
9. **No Docker socket in any container.** The Watchdog is a process supervisor inside the server container; it has no Docker API access and does not create containers.
10. **PostgreSQL is private** (internal network only) and used by Core only. Application admin ≠ database superuser.
11. **Plugin data = typed key/value (JSONB) storage owned by Core**, scoped by plugin and owner. No plugin schemas, no plugin DDL, no arbitrary SQL (ADR-0005). *(Changed from "one schema per plugin installation".)*
12. **Plugin UI is declarative** (descriptors rendered by the web frontend). No plugin-supplied JavaScript in the browser in v1 (ADR-0005). *(Changed from iframe/postMessage bridge.)*
13. **Local persistent media storage** behind a `MediaStorage` interface; media is delivered to providers through short-lived signed URLs served via the web entry point (ADR-0005).
14. **Instagram first, as a separate plugin repository, built after the infrastructure works.** AI text generation, TikTok and further providers come later as plugins.
15. **Initial technology baseline:** see ADR-0003 (C++20 server with a validation gate, TypeScript/Fastify BFF, React/Vite frontend, PostgreSQL, gRPC + Protocol Buffers).

## Supersedes / changes compared to revision 1

| Rev. 1 decision | Rev. 2 |
|---|---|
| 4: Gateway is an internal *module* | Gateway is a separate **process** |
| 5: Watchdog is an internal module, observes only, no restart | Watchdog is **PID 1 supervisor**: starts, restarts (with backoff) and observes processes **inside the server container**; still no Docker control |
| 6: Plugin backend runs in separate, restricted containers | Plugins are **child processes in the server container** (own UID, rlimits); container-per-plugin is a future option for untrusted code |
| 9: No dynamic Docker control | Unchanged; the Watchdog's process control is not Docker control |
| 12: One schema per plugin installation | **No plugin schemas**; Core-owned JSONB key/value storage |
| 14: Core/Gateway/Watchdog single process | Multi-process (see 4) |
| 15: PostAPI review deferred to M12 | Review happens at the start of the Instagram plugin work (Phase B, P0) |

## Consequences

- The server container needs a small privileged supervisor (root with a minimal capability set that is dropped for every child). This is a deliberate, documented attack surface (ADR-0004, T14).
- Plugins and Core share the container's network namespace and filesystem namespace. Isolation depends on per-process UIDs, file permissions, database authentication and rlimits — all of which have explicit acceptance tests.
- The deployment bundle (images + compatibility matrix) and the `.proto` contracts are release-critical artifacts.
- Additional process or container boundaries must be justified by a trust, deployment or failure-isolation need, not by code organization alone.

## Alternatives considered

- **All logic in one process with modules:** rejected after revision — one memory-safety bug would expose the encryption key to every module, and plugins cannot be isolated from Core.
- **Container per plugin:** correct for untrusted code, but needs a narrowly scoped runtime controller (Docker API access) — deferred until third-party plugins are a goal.
- **Plugins as shared libraries (`dlopen`) in the Core process:** rejected; ABI fragility, one crash kills Core, no isolation.
- **Custom full process manager with Docker control:** rejected; a minimal in-container supervisor is enough.
