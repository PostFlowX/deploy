# Open Decisions and Decision Gates

These items are deliberately not hidden inside implementation assumptions. Each must be resolved before the milestone that depends on it.

| ID | Decision | Proposed default | Resolve by |
|###|###|###|###|
| OD-01 | Implementation language/framework for Web/Core/Gateway/Watchdog | Reuse the strongest existing PostAPI language where practical; select one primary stack unless a clear need justifies another | M0.1 |
| OD-02 | Internal transport | Private HTTP/JSON with schema validation over the Compose network for v1; evaluate Unix sockets only if deployment constraints justify them | M0.3 |
| OD-03 | Authentication/session mechanism | Choose server-side sessions or a short-lived token design. Web BFF handles cookie/session transport and browser protections; Core validates session identity and remains authorization authority. Use HttpOnly, Secure, SameSite cookies where compatible, plus CSRF/origin protections for cookie-authenticated mutations | M0.5 |
| OD-04 | Plugin data layout | **Resolved:** one schema per installed plugin (or plugin installation), with owner-scoped records for per-user data; Core checks ownership on every operation | Closed in baseline |
| OD-05 | Plugin runtime provisioning | First release enables controlled/bundled plugin packages; dynamic arbitrary plugin installation waits for Runtime Controller design | M0.4 |
| OD-06 | Plugin UI isolation | Separate origin where practical, restrictive iframe sandbox and narrow message bridge | M0.4 |
| OD-07 | Encryption/key management | Authenticated encryption; key from protected file/Compose secret or deployment secret source, separate from DB backup | M0.5 |
| OD-08 | Media storage | Local persistent volume behind an interface | M0.5 |
| OD-09 | Time and scheduling | UTC persistence plus explicit IANA timezone for user schedules; define DST policy and missed-run behavior | Before job implementation |
| OD-10 | Instagram API prerequisites | Verify current Meta product/API, permissions, account eligibility and app review requirements | Before Instagram milestone |
| OD-11 | Plugin package signing/update policy | Admin-approved packages for MVP; signatures/provenance before public distribution | Before public plugin distribution |
| OD-12 | Release compatibility policy | Deploy repo pins compatible component image versions; one tested release bundle | Before first release |

## Resolved baseline choices

- **Plugin data layout:** use one schema per installed plugin/installation, not one schema per user/plugin pair. Per-user ownership is represented in records and enforced by Core. This reduces schema proliferation and means plugin migrations run once per installation rather than once per user. A plugin schema is organizational, not a security boundary by itself.
- **Web boundary:** `postflowx-web` is a thin BFF plus frontend, not merely a static web server and not a second domain backend. See ADR-0002.
- **Media:** local persistent volume behind a storage interface.
- **Failure recovery:** Docker restart policies own container restarts in v1; Watchdog independently observes and reports health but has no unrestricted Docker control.
- **Plugin installation:** only controlled/bundled or explicitly trusted packages in the first release; arbitrary remote package installation is deferred.
- **Data access:** typed Core storage APIs and controlled migrations; no arbitrary plugin SQL and no plugin DB credentials.

## Decision rules

- Do not block initial scaffolding on decisions whose milestone is later.
- Do not silently choose a security-sensitive default in code.
- Each decision must include the reason, alternatives considered, consequences and tests.
- Update `PRD.md`, `FEATURE_LIST.md`, architecture/specification and roadmap when a decision changes a requirement.
