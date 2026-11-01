# Features

Self-hosted social publishing platform: one Compose installation per customer; users manage provider accounts, prepare content, publish now or scheduled; providers are **plugins**; credentials stay encrypted under the customer's control.
Tags: **P0** must (release blocker) · **P1** should · **P2/P3** later. **[INFRA]** = Infra v0.1 · **[IG]** = Instagram plugin v0.2 · **[LATER]**. `(S n)` = ROADMAP step.

**Roles:** *Admin* (users, roles, plugin grants/enable, health; **no implicit access** to others' content/credentials/DB) · *User* (own accounts, content, jobs; nothing of others) · *Plugin* (scoped identity, admin-granted capabilities, acts for a user only inside a Core-initiated call) · *Operator* (host, Compose, secrets, backups, plugin install via CLI; outside app authorization).
**Success = Infra v0.1 demo script** (ROADMAP Step 11), then Instagram on a real eligible test account.
**Non-goals (v0.1/v0.2):** hosted SaaS · untrusted third-party plugins · UI plugin upload/marketplace · plugin browser code · AI/TikTok/other providers · image/video generation · Kubernetes/HA · analytics, approvals, billing · promises about third-party API availability · a Docker-controlling runtime manager.

## A. Deployment and operations
- **P0 [INFRA]** Compose stack `web/server/db` (+ `proxy` profile), private networks, only web published (default `127.0.0.1`), volumes for DB/media/plugins. (S1)
- **P0 [INFRA]** Health/readiness, structured logs, graceful shutdown in dependency order, pinned images, secrets as files via script, hardened containers (read-only, no caps, limits). (S1–2, S11)
- **P1 [INFRA]** Backup/restore with a tested drill (DB + media, key separate); upgrade/rollback procedure; optional TLS proxy profile. (S11)
- **P2 [LATER]** S3-compatible media storage.

## B. Users, roles, authorization
- **P0 [INFRA]** CLI admin bootstrap; login/logout; server-side sessions; admin manages users/roles; server-side RBAC; **ownership enforced on every operation**; deny-by-default capability checks for plugins; audit of admin, lease and publish actions. (S5, S7–9)
- **P1 [INFRA]** Admin password reset; login rate limiting. (S5)
- **P2 [LATER]** Explicit sharing between users (only with a defined use case).

## C. Server process model
- **P0 [INFRA]** Watchdog as PID 1: start order, restart + backoff, crash loop, zombie reaping, signals, ordered shutdown; per-process UID/caps/`no_new_privs`/rlimits/clean env/private tmp; secret re-homing; independent health sockets; aggregate Docker health with `DEGRADED` for plugin failures. (S2)
- **P0 [INFRA]** Gateway: mTLS from web, per-plugin sockets, method allowlist, limits, deadlines, correlation IDs, identity assignment. (S3)
- **P1 [LATER]** Landlock/seccomp for plugin processes.

## D. Plugin system
- **P0 [INFRA]** Strict manifest + compatibility; registry with lifecycle state and hash-pinned executable; plugin = own process/UID without DB creds/keys/Docker; operator CLI install with read-only volume; admin UI to review/grant/enable/disable/config/health; uninstall with retain/delete. (S7)
- **P0 [INFRA]** Call tokens; Host API (JSONB storage, accounts, credential store/lease, media stream/public URL, checkpoint, audit); declarative UI descriptors; Core-invoked callbacks and manifest tasks. (S8)
- **P1 [INFRA]** SDK + demo plugin with failure injection + manifest validator (in `postflowx-server`). (S8e)
- **P2 [LATER]** UI upload with signatures, staged updates/revocation, catalog; container-per-plugin + egress filtering + strict credential mode; **P3** iframe plugin UIs; multi-version rollback.

## E. Data and secrets
- **P0 [INFRA]** Core-owned `core` schema; checksummed ordered migrations; least-privilege DB roles; credentials encrypted (AEAD, key outside DB, `key_id`); only Core decrypts (plaintext only as a lease to a granted plugin); credential states `ACTIVE/EXPIRING/EXPIRED/REVOKED/REAUTH_REQUIRED`. (S4, S8b)
- **P1 [INFRA]** Media upload validation (magic bytes, size), temp cleanup, quotas. (S8c)
- **P2 [LATER]** Key-rotation tooling, per-user data export/deletion.

## F. Publishing and jobs
- **P0 [INFRA]** Posts (draft, media refs, target account, provider options); durable job state machine with attempts, leases, bounded retries, terminal states; immediate + scheduled (UTC + IANA zone, DST/missed-window policy); idempotency keys; distinct handling of expired token / rate limit / transient / permanent; restart recovery; `OUTCOME_UNKNOWN` + `Reconcile` + user decision when undecidable. (S9)
- **P1 [INFRA]** Job history, user-facing error explanations, admin diagnostics. (S9–10)
- **P2 [LATER]** Retry tuning, bulk operations, recurring schedules.

## G. Web application
- **P0 [INFRA]** Frontend + thin BFF (typed calls via Gateway, no DB); cookie/session + CSRF/Origin; shell, auth views, degraded screen; admin UI (users, plugins, health); user UI (accounts, composer with schema-driven options, media, jobs); generic OAuth-callback and public-media routes. (S6, S8, S10)
- **P1 [INFRA]** Accessible validation/loading/error states, responsive layout. (S10)

## H. Instagram plugin (own repo)
- **P0 [IG]** Verified prerequisites (P0) · OAuth connect + token storage/refresh via task (P1) · immediate publish with checkpoint/reconcile (P2) · scheduled publish, error-class mapping, rate limits (P3).
- **P1 [IG]** Carousel/reel as the API permits (P3) · no credentials in UI/logs, documented permissions and limits (P4).

## I. Later plugins
**P2 [LATER]** AI text generation (`ai_text` kind: review before publishing, timeout/rate/cost limits) · TikTok after API feasibility · further providers.

## J. Quality
- **P0 [INFRA]** Unit/integration/contract/authorization/deploy smoke tests; sanitizers in CI; rate/size/timeout/concurrency limits; threat-model tests and failure injection ([`SECURITY.md`](SECURITY.md) §4). (S1+, S11)
- **P1 [INFRA]** Dependency/image scanning, SBOM. **P2** load test.
