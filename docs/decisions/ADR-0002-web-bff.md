# ADR-0002: Web Application as a Thin Backend-for-Frontend

- **Status:** Proposed baseline decision
- **Date:** 2026-10-19

## Context

The browser needs HTTP routes, session/cookie handling, frontend delivery and a safe interface to internal application operations. A static-file server alone cannot provide the required browser-facing behavior. Conversely, putting domain logic and database access in the Web tier would duplicate Core responsibilities and create another authorization path.

## Decision

1. `postflowx-web` is a web application containing the frontend and a thin Backend-for-Frontend (BFF).
2. The BFF owns browser-facing HTTP/API routes, cookie/session transport, CSRF and other browser-facing protections, request/response shaping, and forwarding typed operations through the IPC Gateway.
3. Core owns authoritative authentication/session validity, identity, role and capability checks, resource ownership, business rules, secrets and data access. The exact session mechanism remains open until M0.5, but the BFF must not become an independent source of authorization truth.
4. Web never connects directly to PostgreSQL and does not contain a second implementation of domain logic.
5. A standalone Nginx/Caddy reverse proxy is optional, not a required application component for the initial stack. It may later be added for TLS termination, static asset delivery or deployment-specific routing.
6. Plugin UI is delivered/routed through a controlled Web path or configured separate origin, but runs in an isolated browser context with a narrow message bridge. It receives no session secrets or unrestricted Core RPC.

## Consequences

- The Web service is more than a static server, but remains deliberately thin.
- Browser requests follow `Browser → Web BFF → IPC Gateway → Core → PostgreSQL` for protected application operations.
- Core authorization tests remain authoritative; hiding a control in the UI is never sufficient.
- Web and Core require compatible API contracts and versioning.
- Cookie-authenticated mutation routes require CSRF protection, secure cookie settings and origin checks appropriate to the chosen deployment.

## Alternatives considered

- **Static server only:** rejected as the complete Web design because session-aware routes and safe request forwarding are required. A static server/reverse proxy may still be used as an optional edge component.
- **Full business backend in Web:** rejected because it duplicates Core, data access and authorization responsibilities.
- **Direct browser-to-Core/Gateway calls:** rejected as the default because it exposes internal service contracts and complicates service authentication and browser security.
