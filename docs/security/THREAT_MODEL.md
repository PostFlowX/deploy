# Threat Model

**Status:** Initial threat model; must be revisited before public third-party plugins are enabled.

## 1. Assets

- Social account access tokens, refresh tokens and client secrets.
- User identity/session data and role grants.
- Draft content, media files, publishing schedules and history.
- PostgreSQL contents and migration state.
- Encryption keys and deployment secrets.
- Plugin packages, manifests and update artifacts.
- Integrity of published content and audit events.
- Availability and recoverability of the installation.

## 2. Actors and assumptions

### In scope

- Malicious or compromised plugin author.
- Buggy plugin that sends malformed requests or attempts cross-user access.
- Authenticated user attempting to access another user's resources.
- Unauthenticated remote attacker targeting the public Web entry point.
- Compromised frontend/plugin UI attempting to steal session data.
- Dependency or plugin package compromise.
- Accidental operator error, failed upgrade, expired token or process crash.

### Assumptions

- The host administrator and deployment operator can ultimately control the host. Application-level controls cannot protect data from a fully compromised host/root operator.
- Social platform API permissions and behavior are controlled by the external platform.
- Docker containers are useful isolation boundaries but not equivalent to a security proof or VM boundary.
- A plugin manifest is not inherently trustworthy.
- Initial deployments may be single-host and are not designed for hostile multi-tenant hosting of unrelated customers on one shared host.

## 3. Trust boundaries

1. Public browser to Web BFF.
2. Web to internal Gateway/Core.
3. Plugin UI to main frontend.
4. Plugin backend to Core services.
5. Core to database and secret key source.
6. Plugin package/update source to installed runtime.
7. Application containers to host/Compose operator.

## 4. Threats and mitigations

### T0 — Browser session abuse / CSRF

**Risk:** An attacker tricks an authenticated browser into making state-changing requests or abuses a weak session boundary.
**Mitigations:** HttpOnly/Secure/SameSite cookie settings as compatible; CSRF tokens and/or strict Origin checks for cookie-authenticated mutations; session rotation/expiry and logout invalidation; Core validates session context and authorization on every protected operation. Exact mechanics are fixed at M0.5.

### T1 — Cross-user data exposure

**Risk:** User A reads or changes User B's account, job, plugin data or secret.  
**Mitigations:** Core-derived actor identity; ownership checks on every operation; deny-by-default authorization; tests for horizontal and vertical privilege escalation; no trust in user IDs supplied by the client/plugin.

### T2 — Malicious plugin steals tokens or data

**Risk:** Plugin exfiltrates all database records, secrets or host files.  
**Mitigations:** No DB credentials; no unrestricted SQL; capability-based Core API; per-user scopes; no host mounts or Docker socket; non-root runtime; read-only root filesystem where practical; drop Linux capabilities; resource limits; outbound network policy where feasible; audit sensitive operations. Explain residual risk: an authorized plugin can still misuse data it is legitimately allowed to read or send externally.

### T3 — Plugin UI compromises the main app

**Risk:** UI script accesses main DOM/session or forges privileged requests.  
**Mitigations:** Isolated iframe/origin; restrictive CSP and sandbox; no `allow-same-origin` combined with untrusted scripts unless separately justified; narrow `postMessage` bridge validating `origin`, `source`, message schema and allowed actions; no tokens in URLs; short-lived scoped context where needed.

### T4 — IPC spoofing or privilege escalation

**Risk:** A plugin claims another plugin/user identity or calls admin-only operations.  
**Mitigations:** Authenticate service identities at the transport boundary; Core validates grants and actor context; message IDs and protocol version; schema validation; strict route allowlist; deadlines and rate limits; do not authorize based only on fields inside a message.

### T5 — SQL injection/schema confusion

**Risk:** Plugin input changes SQL structure or exploits `search_path`.  
**Mitigations:** Parameterized values; allowlisted/quoted identifiers generated from immutable internal IDs; explicit schema qualification; safe `search_path`; revoke unnecessary `CREATE` on `public`; controlled migrations; no arbitrary SQL endpoint.

### T6 — Secret/key compromise

**Risk:** Database dump includes usable credentials or key leaks through logs.  
**Mitigations:** Authenticated encryption at rest; encryption key stored separately from ciphertext; restricted file/secret permissions; key rotation plan; redact logs; do not return plaintext secrets to browser/plugin; test backup and restore with key handling documented.

### T7 — Malicious package or supply-chain update

**Risk:** A compromised package executes arbitrary code after installation.  
**Mitigations:** Admin approval; pinned versions and digests; package provenance/signatures before public distribution; compatibility checks; staged update/rollback; dependency and image scanning; no automatic installation of arbitrary remote code in MVP.

### T8 — SSRF or unauthorized outbound network

**Risk:** Plugin or API input accesses internal metadata services or local network endpoints.  
**Mitigations:** Restrict plugin egress where possible; block access to host/internal control endpoints; validate URLs and redirect behavior; do not let user-controlled URLs be fetched without an explicit safe-fetch design.

### T9 — Duplicate or lost publishing

**Risk:** Network failure occurs after external platform accepts a post but before Core records success.  
**Mitigations:** Durable job state, attempt history, external post IDs, idempotency where supported, explicit `OUTCOME_UNKNOWN`, reconciliation before retry. Do not promise exactly-once delivery when the external API cannot guarantee it.

### T10 — Resource exhaustion

**Risk:** Plugin or upload consumes CPU, memory, disk, connections or queue capacity.  
**Mitigations:** Container limits, request/upload size limits, timeouts, bounded queues/concurrency, quotas, cleanup, rate limiting and crash-loop detection.

### T11 — Watchdog/Gateway failure hides system state

**Risk:** One monitoring/communication failure is misreported as total system failure.  
**Mitigations:** Independent health observation paths; separate `UNKNOWN` from `UNRESPONSIVE`; Watchdog must not rely solely on Gateway; monitor Watchdog itself through Docker/operator health.

### T12 — Backup or upgrade damages data

**Risk:** Restore misses media/keys or migration leaves schema inconsistent.  
**Mitigations:** Coordinated database + media backup; explicit key-backup policy; tested restore drills; versioned migrations; pre-upgrade backup; rollback or forward-recovery instructions.

## 5. Security requirements for MVP

- No plugin can access PostgreSQL directly.
- No application service except the approved Core data layer receives DB credentials.
- No service other than the Web entry point is exposed to the host by default.
- No container receives the Docker socket in v1.
- Secrets are never logged or placed in URLs.
- Every sensitive operation has server-side authorization tests.
- Plugin UI and backend are treated as separate trust domains.
- Admin actions and secret access are auditable.
- Unknown protocol versions and capabilities fail closed.
- Production images are pinned and built from reviewed sources.

## 6. Residual risks and limits

- A host/root compromise can read application memory, volumes and keys.
- A plugin can misuse data within the scope explicitly granted to it.
- Container isolation depends on host kernel/runtime security.
- External social APIs may change, rate-limit, reject or delay operations.
- Without platform-supported idempotency, an ambiguous publication result cannot always be resolved automatically.

## 7. Required security tests

- Cross-user read/write attempts for every resource family.
- User cannot grant themselves admin/plugin capabilities.
- Plugin cannot access another plugin's instance or user scope.
- Invalid IPC identity, malformed payload, stale protocol version and oversized request are rejected.
- Plugin UI cannot read main application DOM or access privileged message actions.
- DB credentials are absent from plugin environment and container mounts.
- Secret ciphertext is useless without the separately held key; logs contain no token values.
- Schema identifier injection and unsafe `search_path` cases are tested.
- Plugin crash, resource exhaustion and gateway outage do not corrupt durable jobs.
