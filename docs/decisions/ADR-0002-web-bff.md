# ADR-0002: Web Application as a Thin Backend-for-Frontend

- **Status:** Proposed baseline — **revision 2** (2026-10-22)
- **Date:** 2026-10-19 (revised 2026-10-22)

## Context

The browser needs HTTP routes, session/cookie handling, frontend delivery and a safe interface to internal application operations. A static-file server alone cannot provide that. Putting domain logic or database access into the web tier would duplicate Core responsibilities and create a second authorization path.

Revision 2 adds three browser-facing duties that follow from the plugin model: OAuth callbacks for provider account connections, a public endpoint for short-lived signed media URLs, and rendering of declarative plugin descriptors.

## Decision

1. `postflowx-web` is one container with the **frontend (React SPA)** and a **thin BFF (Fastify)**.
2. The BFF owns: browser-facing HTTP/API routes, cookie/session *transport*, CSRF/origin protection, request validation and shaping, error mapping, and forwarding typed calls to the server **Gateway** over gRPC with mutual TLS.
3. **Core remains authoritative** for session validity, identity, roles, capabilities, ownership, business rules, secrets and data access. The BFF is never a source of authorization truth.
4. The web container **never connects to PostgreSQL** and contains no domain logic.
5. **Generic, allowlisted pass-through routes** (no plugin-specific code in the BFF):
   - `GET /api/connect/{plugin_id}/callback` — receives the provider's OAuth redirect and forwards the raw query parameters plus the user's session to Core (`accounts.complete_connect`). Core validates the single-use `state`, binds it to the session user, and calls the plugin.
   - `GET /media/public/{token}` — unauthenticated by session, authenticated by an unguessable, expiring, signed token. The BFF forwards the token to Core (`media.resolve_public`) and streams the result. Core validates token, expiry and revocation. This is what lets providers such as Meta fetch media from a public URL.
6. **Plugin UI is declarative.** The frontend renders forms and pages from plugin *descriptors* (restricted JSON-Schema subset, ADR-0005). All plugin-supplied strings are treated as untrusted text and are rendered escaped; no plugin-supplied HTML or JavaScript is executed in v1.
7. **TLS/ingress.** The web container listens on plain HTTP inside the stack and is bound to `127.0.0.1` by default. For anything beyond localhost, TLS termination is required: either the optional Compose profile `tls` (Caddy, automatic certificates) or an operator-provided proxy. HTTPS is mandatory for Instagram (OAuth redirect URI and public media URLs).
8. **Internal transport:** the BFF authenticates to the Gateway with a client certificate (mTLS). A user identity is conveyed only as an opaque session token that Core validates; the BFF never sends a trusted user ID.

## Consequences

- Request path for protected operations: `Browser → Web BFF → Gateway → Core → PostgreSQL`.
- The web service is more than a static server but stays deliberately thin; hiding a UI control is never sufficient — Core re-authorizes everything.
- Cookie-authenticated mutation routes require CSRF protection, secure cookie attributes and origin checks (details: OD-03 / M0.4).
- The BFF must stay up to date with the contract (`proto/` in the deploy repository); contract tests run in CI (ADR-0003).
- The public media endpoint and the OAuth callback are new attack surface and are covered in the threat model (T17, T18).
- When Core/Gateway are unavailable the BFF serves the UI shell with a clear degraded state instead of failing blindly.

## Alternatives considered

- **Static server only:** cannot provide sessions, callbacks or media delivery.
- **Browser talks to server/Gateway directly:** exposes the internal API and moves cookie/CSRF concerns into the C++ server.
- **Plugin-specific BFF routes:** rejected; every plugin would need web-tier code. The generic callback and media routes keep plugins out of the web container.
- **Plugin UI in sandboxed iframes:** deferred; far larger attack surface and effort than descriptors, which cover the first provider completely.
