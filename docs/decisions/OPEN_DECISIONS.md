# Open Decisions and Decision Gates

**Revision 2 (2026-10-22).** Each item is resolved before the milestone that depends on it. "Proposed" values are defaults that code may assume only after the resolving milestone has recorded them.

| ID | Decision | Status | Default / proposal | Resolve by |
|---|---|---|---|---|
| OD-01 | Server language/toolchain | **Accepted with gate** | C++20 (ADR-0003). Gate: M0.2 spike must pass; otherwise revisit via ADR before M1 | M0.2 |
| OD-02 | Internal transport | **Resolved** (details open) | gRPC + Protobuf; UDS inside the server container, TCP + mTLS web↔server (ADR-0004). Open: generic Gateway proxying, peer identity on UDS | M0.2 / M0.3 |
| OD-03 | Authentication/session mechanism | Proposed | Server-side opaque sessions stored hashed in the DB; random 256-bit session ID; HttpOnly + Secure + SameSite=Lax cookie held by the BFF; absolute + idle expiry; rotation on login/privilege change; CSRF via Origin check + synchronizer token for mutations; Argon2id password hashing (libsodium) | M0.4 |
| OD-04 | Plugin data layout | **Resolved (changed)** | Core-owned JSONB key/value table; no plugin schemas/DDL (ADR-0005) | closed |
| OD-05 | Plugin runtime / hosting | **Resolved (changed)** | Native executables as child processes in the server container, one UID per plugin; only bundled/operator-approved plugins in v1 (ADR-0004) | closed |
| OD-06 | Plugin UI | **Resolved (changed)** | Declarative descriptors rendered by the web frontend; iframe UI deferred (ADR-0005) | closed |
| OD-07 | Encryption / key management | Proposed | libsodium XChaCha20-Poly1305 AEAD; 32-byte master key from secret file; per-record random nonce; `key_id` stored with ciphertext; rotation = re-encrypt with new key ID; key backed up separately from DB backups | M0.4 |
| OD-08 | Media storage | **Resolved** | Local volume behind `MediaStorage`; signed, expiring public URLs for providers (ADR-0002/0005); S3 later | closed |
| OD-09 | Time and scheduling | Proposed | Persist UTC instant + IANA zone. Nonexistent local time (DST gap) → next valid instant; ambiguous local time (DST overlap) → first occurrence; UI shows the resolved instant. Late job: run if within `missed_window` (default 15 min), otherwise `FAILED(MISSED_WINDOW)` and user must reschedule | M0.4 (before M10) |
| OD-10 | Instagram API prerequisites | Open (research) | Verify current Meta product/API, account eligibility (Business/Creator, linked Page), permissions, app review, media constraints, token lifetimes. Recorded as a document in M0.5; confirmed again in P0 | M0.5 / P0 |
| OD-11 | Plugin package trust / signing | Proposed | v1: operator CLI install, SHA-256 pinning, manifest validation. UI upload + signatures/provenance only before third-party distribution | before Phase C |
| OD-12 | Release compatibility policy | Proposed | Deploy repo pins exact image versions/digests; one tested bundle; compatibility matrix includes proto version and plugin API range | M12 |
| OD-13 | Watchdog implementation | Proposed | Custom minimal watchdog (needed for UID pools, hash-checked plugin start, secret re-homing). Re-evaluate s6-overlay for the *static* part only if the custom effort exceeds one L-size milestone | M0.2 / M3 |
| OD-14 | Plugin language, ABI and SDK | Proposed | Contract is language-neutral. Artifact must run in the server image (static binary or built on the pinned base image). SDK + reference plugin in C++ first; Instagram plugin language decided at P0 (default C++ with the SDK) | M9 / P0 |
| OD-15 | Secret delivery inside the server container | Proposed | Watchdog (root + `DAC_READ_SEARCH`) reads `/run/secrets/*` and re-homes per-process copies on tmpfs (0400, owner = process UID); fallback: env/FD hand-off to the watchdog only. Acceptance test: plugin UID reads none of them | M0.2 / M1.2 |
| OD-16 | Contract workflow | **Decided: `proto/` in the deploy repo** (details proposed) | All `.proto` files live in `proto/` of this repo; version = deploy-repo tag (= release bundle). Consumers (server, web, SDK, plugin repos) pin a tag/commit and fetch only `proto/` (sparse checkout, submodule or sync script — pick in M1.1); generated code is not committed. `buf lint` + `buf breaking --against <previous release tag>` in this repo's CI | M0.3 / M1.1 |
| OD-17 | TLS / ingress | Proposed | Optional Compose profile `tls` (Caddy). HTTPS mandatory for Instagram in production (OAuth redirect URI, public media URLs) | M12 |
| OD-18 | License | **Open (needs maintainer)** | Choose before inviting contributors (README asks for help). Add `LICENSE` and a short `CONTRIBUTING.md` | before first public contribution |
| OD-19 | PostgreSQL client library and migration runner | Proposed | libpq with thin RAII wrapper (or libpqxx); prepared statements only; own runner with ordered, checksummed `.sql` files, advisory lock, one transaction per migration | M0.4 / M5 |
| OD-20 | Initial administrator bootstrap | Proposed | CLI in the server image: `postflowx-admin create-admin` (one-off `docker compose run`); no default credentials; no first-visitor-wins setup page | M6 |
| OD-21 | Core ↔ Gateway trust | Proposed | Core accepts connections only on its socket, accessible only to the Gateway UID; Gateway assigns `x-pfx-caller-*` metadata and strips client-supplied `x-pfx-*`; Core additionally validates plugin identity against call tokens | M0.2 / M4 |

## Resolved baseline choices

- **Containers:** `web`, `server`, `db` (+ optional `proxy`). **Processes inside `server`:** watchdog (PID 1), gateway, core, one process per enabled plugin.
- **Boundaries:** Core = single owner of authorization, secrets, jobs, DB access. Gateway = routing + caller identity. Watchdog = process lifecycle inside the server container. Docker/Compose = container lifecycle. Web BFF = browser concerns only.
- **No Docker socket** anywhere; the Watchdog is not a Docker controller.
- **Plugins:** native executables from a read-only plugin volume; installed by operator CLI; managed (enable/disable/grants/config/health) in the web UI; no untrusted third-party code in v1.
- **Plugin user context** only through Core-issued call tokens (ADR-0005).
- **Publishing:** Core owns the state machine; plugins report outcome classes; ambiguous outcomes → `OUTCOME_UNKNOWN` + reconcile (ADR-0005).
- **Instagram:** separate repository, built after the infrastructure milestone "Infra v0.1" passes its release gate.

## Decision rules

- Do not block initial scaffolding on decisions whose milestone is later.
- Do not silently choose a security-sensitive default in code.
- Each decision records the reason, alternatives, consequences and tests.
- Update `PRD.md`, `FEATURE_LIST.md`, architecture, protocol, plugin spec and roadmap when a decision changes a requirement.
- Any change to a process boundary, trust assumption or the plugin contract requires an ADR.
