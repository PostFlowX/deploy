# Threat Model

**Status:** Initial threat model — **revision 2** (2026-10-22). Re-evaluated because plugins now run as processes **inside** the server container (ADR-0004). Must be revisited before any untrusted third-party plugin support (Phase C).

## 1. Assets

- Provider access/refresh tokens and client secrets.
- User identity, sessions, role grants, password hashes.
- Draft content, media files, schedules, publishing history.
- PostgreSQL contents and migration state.
- **Master encryption key**, database password, internal TLS keys.
- Plugin packages and their pinned hashes.
- Integrity of published content and audit events.
- Availability and recoverability of the installation.

## 2. Actors and assumptions

### In scope

- Unauthenticated remote attacker against the public web entry point.
- Authenticated user attempting to reach another user's data or admin functions.
- Buggy or compromised **bundled/operator-approved plugin** (including a plugin that was compromised through its own dependencies).
- Compromised BFF/web container.
- Malicious content from a provider (callback parameters, API responses, plugin descriptors).
- Accidental operator error, failed upgrade, expired token, process crash.
- Supply-chain compromise of dependencies, images or plugin packages.

### Assumptions

- The host administrator/operator can ultimately control the host; application controls do not protect against a compromised host or root on it.
- **v1 plugins are trusted by policy** (bundled or explicitly approved by the operator). Process isolation limits blast radius and enforces the API boundary; it is **not** designed to contain deliberately hostile code (shared kernel, network namespace, egress).
- Containers are useful isolation but not a VM boundary.
- Provider API behavior is controlled by the provider.
- Single-host deployment; no hostile multi-tenant hosting of unrelated customers on one host.

## 3. Trust boundaries

1. Public browser ↔ Web BFF.
2. Web container ↔ Gateway (mTLS).
3. Gateway ↔ Core (UDS, UID-restricted socket).
4. Plugin process ↔ Gateway/Core (per-plugin socket, call tokens).
5. Core ↔ PostgreSQL and the key source.
6. Watchdog (root) ↔ all other processes in the server container.
7. Operator ↔ host/Compose/secrets/plugin installation.
8. Provider/internet ↔ plugin (egress) and ↔ public web routes (callback, media).

## 4. Threats and mitigations

### T0 — Browser session abuse / CSRF
**Risk:** forged state-changing requests or weak session handling.
**Mitigations:** HttpOnly + Secure + SameSite cookies; strict Origin check plus synchronizer token for mutations; session rotation on login/privilege change, idle + absolute expiry, logout invalidates server-side; Core validates the session on every call; login rate limiting. Exact mechanics fixed in M0.4.

### T1 — Cross-user data exposure
**Risk:** user A reads/changes user B's accounts, posts, media, jobs, credentials or plugin data.
**Mitigations:** actor derived by Core from session/call token only; ownership checks in every operation; deny by default; owner column set by Core for plugin storage; horizontal/vertical privilege tests for every resource family; unknown resources return `NOT_FOUND` rather than revealing existence.

### T2 — Malicious or compromised plugin (in-container)
**Risk:** a plugin exfiltrates data, abuses its capabilities or attacks other components.
**Mitigations:** no DB credentials/keys/Docker; capability grants reviewed by the admin; user context only via call tokens (cannot act outside a Core-initiated call); own UID, dropped capabilities, `no_new_privs`, rlimits, cleared environment, private tmp; read-only plugin directory with hash-pinned executable; per-plugin rate/concurrency limits; audit of sensitive operations.
**Residual risk:** a plugin can use data it is legitimately allowed to read (including leased tokens), can send data to any host via the shared `egress` network, and can attempt direct connections to PostgreSQL (stopped by authentication, not by network). **Therefore v1 supports only bundled/operator-approved plugins.**

### T3 — Plugin UI compromises the main app *(not applicable in v1)*
Plugins ship no browser code in v1 (declarative UI). If iframe-based UIs are introduced (Phase C), this threat returns with: distinct origin, restrictive sandbox/CSP, no `allow-same-origin` with untrusted scripts, narrow `postMessage` bridge. See T19 for the v1 variant.

### T4 — Call-token misuse and plugin impersonation
**Risk:** a plugin presents another plugin's or user's token, replays an old token, or invents a user ID.
**Mitigations:** tokens are random (256-bit), stored hashed, bound to (plugin, user, purpose, scope, expiry); Core compares token plugin with the **Gateway-assigned** identity; expiry ≤ call deadline; revocation on disable/capability revoke; no user ID fields in Host API requests.

### T5 — SQL injection / schema confusion
**Risk:** injected SQL or unsafe `search_path`.
**Mitigations:** prepared statements only; no dynamic identifiers (no plugin schemas, no DDL from plugins); fixed schema qualification and reviewed `search_path`; `CREATE` on `public` revoked; separate migration and runtime roles.

### T6 — Secret/key compromise
**Risk:** database dump yields usable credentials, or the key leaks via logs/backups.
**Mitigations:** AEAD encryption with a key outside the database and outside DB backups; `key_id` and rotation procedure; typed secret wrappers in C++ that cannot be logged; restricted file permissions; secrets re-homed per process on tmpfs; no plaintext secrets to browser/BFF; tests for backup+restore with key handling.

### T7 — Malicious package or supply-chain update
**Risk:** compromised plugin package, dependency or base image executes arbitrary code.
**Mitigations:** install only via operator CLI; manifest validation; SHA-256 pinning of every file, verified by the Watchdog before exec; read-only plugin volume; pinned image versions/digests; dependency/image scanning and SBOM; no automatic remote installation. Signatures/provenance before any public distribution.

### T8 — SSRF / unauthorized outbound network
**Risk:** plugin or user-controlled URLs reach internal services or exfiltrate data.
**Mitigations:** `backend` is an internal network (no internet) and only the server has `egress`; Core and Gateway perform no user-URL fetches; plugins must validate URLs they fetch; `egress_hosts` documented for review. **Not enforced in v1** (shared network namespace); future: per-UID egress filtering or container-per-plugin.

### T9 — Duplicate or lost publishing
**Risk:** provider accepts a post but Core records no success; retry duplicates it.
**Mitigations:** durable jobs and attempts; `DISPATCHED` marker written before the plugin call; `OUTCOME_UNKNOWN` after any ambiguity; plugin checkpoints + `Reconcile`; idempotency keys; no automatic retry unless `NOT_PUBLISHED`; user decision when undecidable. No exactly-once promise.

### T10 — Resource exhaustion
**Risk:** plugin/upload/request floods CPU, memory, disk, connections or queue.
**Mitigations:** container limits; per-process rlimits and pids limit; request/upload/message size limits; bounded queues and concurrency; per-caller rate limits at the Gateway; plugin storage quotas; temp cleanup; crash-loop detection.

### T11 — Observation failure hides system state
**Risk:** one failed monitoring path is misreported as total outage (or hides one).
**Mitigations:** independent health sockets (Watchdog does not depend on the Gateway); `UNKNOWN` vs `UNRESPONSIVE` vs `CRASH_LOOP`; aggregate rules documented; the Watchdog cannot observe its own death — Docker's container health/restart handles that boundary.

### T12 — Backup or upgrade damages data
**Risk:** restore misses media/keys or a migration leaves an inconsistent schema.
**Mitigations:** coordinated DB + media backup; separate key backup policy; versioned, checksummed, transactional migrations; mandatory pre-upgrade backup; tested restore and upgrade drills; documented rollback/forward-recovery.

### T13 — Gateway compromise or identity spoofing
**Risk:** a bug in the Gateway lets a caller obtain another identity (e.g. plugin as `web`, or forged `x-pfx-*` metadata).
**Mitigations:** Gateway is minimal and holds no secrets except its TLS key; strips all client-supplied `x-pfx-*`; identity from mTLS certificate or per-plugin socket only; Core listens on a UID-restricted socket and re-validates call tokens and capabilities; method allowlist per caller kind; fuzz/negative tests.
**Residual risk:** Gateway is part of the trusted computing base for web-origin identity.

### T14 — Watchdog privileged surface
**Risk:** the root supervisor is abused to run arbitrary code, escalate or leak secrets.
**Mitigations:** minimal capabilities (`SETUID`, `SETGID`, `CHOWN`, `KILL`, `DAC_READ_SEARCH`), no network listener, no Docker access, control socket restricted to the Core UID; `StartPlugin` accepts only (id, version) and executes only a hash-verified regular file inside the plugin directory (path containment, no symlink escape); children drop all capabilities and set `no_new_privs`; small code size with focused tests and sanitizers.
**Residual risk:** a Core compromise can restart/stop plugins; a Watchdog memory-safety bug is high impact — hence its small scope.

### T15 — Plugin reaches Core's secrets or database (shared container)
**Risk:** a plugin reads secret files, `/proc` of Core, Core's state or media, or authenticates to PostgreSQL.
**Mitigations:** distinct UIDs; secrets only in 0400 files owned by the consuming UID on tmpfs; `/run/secrets/*` unreadable to plugin UIDs; non-dumpable, no-ptrace across UIDs; Core state and media directories `0700`; PostgreSQL SCRAM with a password only Core can read; PostgreSQL reachable only on `backend`.
**Residual risk:** network reachability of PostgreSQL from plugin processes (authentication only); kernel-level privilege escalation.

### T16 — Credential lease abuse
**Risk:** a plugin leases and misuses/exfiltrates tokens, or leases tokens of accounts outside the current call.
**Mitigations:** `LeaseCredential` requires the `credentials.lease` grant and a call token scoped to that user/account/purpose; every lease is audited (plugin, user, account, purpose); short lease lifetime; admin can revoke grants immediately; plugin guidelines (memory-only, never logged). Variant B (Core performs provider calls) reserved for untrusted plugins.
**Residual risk:** a trusted-by-policy plugin that is compromised can exfiltrate tokens it leases during legitimate calls.

### T17 — Public media endpoint abuse
**Risk:** token guessing, token leakage, hotlinking, or exposure of media beyond the intended window.
**Mitigations:** 256-bit random tokens stored hashed; short TTL (default minutes), revocable, scoped to one media object; Core validates every request; no directory listing or enumeration; rate limiting; no cookies/ambient authority on the route; media volume never exposed directly.

### T18 — OAuth callback abuse
**Risk:** login CSRF / account-linking attacks, code injection, open redirects.
**Mitigations:** Core-generated, single-use, short-TTL `state` bound to the session user; BFF forwards raw parameters and never interprets them; Core consumes `state` before calling the plugin; callback route is generic and allowlisted by plugin ID; redirect targets are fixed by Core; plugin treats callback parameters as untrusted.

### T19 — Malicious descriptor content (declarative UI)
**Risk:** a compromised plugin injects script or deceptive UI via descriptor fields, icons or error messages.
**Mitigations:** restricted JSON-Schema subset validated by Core; all strings rendered as escaped text; SVG icons sanitized and size-limited; no plugin HTML/JS; length limits; strict CSP on the web app; error messages from plugins treated as untrusted text.

## 5. Security requirements for Infra v0.1

- No plugin has database credentials or key material; no plugin UID can read secret files or other UIDs' `/proc`.
- No container receives the Docker socket; only the web entry point is published.
- Secrets are never logged or placed in URLs.
- Every sensitive operation has server-side authorization tests.
- User context for plugins exists only via Core-issued call tokens.
- Admin actions, credential leases and capability changes are audited.
- Unknown protocol versions, capabilities and callers fail closed.
- Production images are pinned and built from reviewed sources; plugin executables are hash-verified before start.

## 6. Residual risks and limits

- A host/root compromise can read application memory, volumes and keys.
- A trusted plugin can misuse any capability and token lease it legitimately has, and has unrestricted outbound network access.
- Container and process isolation depend on the host kernel and runtime.
- The Gateway is in the trusted computing base for web-origin identity; the Watchdog is a small privileged component.
- Provider APIs may change, rate-limit, reject or delay operations; ambiguous publication results cannot always be resolved automatically.

## 7. Required security tests

- Cross-user read/write attempts for every resource family; user cannot grant themselves admin or plugin capabilities.
- **Plugin UID** cannot read `/run/secrets/*`, `/run/postflowx/secrets/*`, Core state, media volume, or `/proc/<pid>/{environ,mem,fd}` of other UIDs; cannot connect to another plugin's socket; cannot authenticate to PostgreSQL; cannot signal other processes.
- Call token: expired, replayed after revoke, wrong plugin, wrong user scope, missing token on user-scoped call → rejected.
- Gateway: unauthenticated caller, wrong caller kind for a method, forged `x-pfx-*`, oversized message, expired deadline, unsupported protocol version → rejected and logged.
- Watchdog: `StartPlugin` with path traversal, symlink escape, hash mismatch, unknown plugin → rejected; crash loop stops restarts; children carry no capabilities.
- Descriptor/UI: script and HTML injection in plugin strings and SVG icons does not execute.
- OAuth: reused, expired, foreign-session and missing `state` → rejected.
- Public media: expired, revoked, guessed and cross-object tokens → rejected.
- Secret ciphertext is useless without the separately held key; logs and audit events contain no token values; restore drill with and without the key.
- Plugin crash, resource exhaustion, Gateway outage, DB outage and Core crash **during a dispatched attempt** do not corrupt or duplicate durable jobs (`OUTCOME_UNKNOWN` path exercised).
