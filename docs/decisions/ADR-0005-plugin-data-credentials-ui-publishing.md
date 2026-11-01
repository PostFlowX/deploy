# ADR-0005: Plugin Data, Credentials, Call Tokens, Declarative UI and Publishing Contract

- **Status:** Proposed baseline (new, 2026-10-22)
- **Related:** ADR-0004, PLUGIN_SPEC, IPC_PROTOCOL, THREAT_MODEL (T1, T2, T6, T9, T16–T19)

## Context

With plugins as separate processes in the server container (ADR-0004), the contract between Core and a plugin determines both the security properties and how much work each plugin costs. The earlier drafts specified per-plugin database schemas, `secrets.use` without secret release, iframe-based plugin UIs and a generic capability model. For the first (and so far only) provider that is more machinery than needed, and the Instagram plugin *must* make provider API calls itself, which requires the access token in the plugin process.

## Decision

### 1. Plugin never acts on its own for a user — **call tokens**

All user-scoped work is **initiated by Core**: connect flow, OAuth callback, validation, publishing, reconciliation, scheduled per-account tasks. With every such call Core passes a **call token**: an opaque, random, single-purpose token bound to *(plugin ID, user ID, purpose, optional job/account ID, expiry)*. Every user-scoped Host API call from the plugin must carry it. Core checks that

- the token exists and is not expired or revoked,
- the **plugin identity assigned by the Gateway** matches the token's plugin,
- the requested operation and resource are within the token's scope and the plugin's granted capabilities.

A plugin therefore cannot choose a user ID, cannot impersonate another user and cannot act for a user outside an active Core-initiated call. Token lifetime is bounded by the call deadline (default ≤ 5 min; job attempts: lease duration).

### 2. Plugin storage: typed key/value (JSONB), owned by Core

- One Core table `plugin_data(plugin_id, owner_user_id NULL, collection, key, value JSONB, version, updated_at)`. `owner_user_id` is set from the call token, never from plugin input; `NULL` means plugin-global data (plugin identity only).
- Operations: `Get`, `Put` (with `expected_version` for optimistic concurrency), `Delete`, `List(collection, prefix, limit)`.
- Limits (configurable): value ≤ 256 KiB, per-plugin quota, key charset/length restrictions.
- **No plugin schemas, no DDL, no plugin-supplied migrations, no SQL.** Core schema migrations are Core's. If a future plugin needs relational data, that is a new ADR.
- Uninstall requires an explicit data disposition (retain / export / delete).

### 3. Credentials: Core stores, plugin **leases**

- Core owns the `social_accounts` and `credentials` records. Credential payloads are encrypted at rest (AEAD, key outside the database, key ID stored with the ciphertext for rotation).
- A plugin stores a credential after OAuth via `StoreCredential(account_id, payload, expires_at, metadata)` (call token required) and retrieves it for an operation via `LeaseCredential(account_id)`, which returns the plaintext payload and an `expires_at` for the lease.
- **Accepted trade-off (variant A):** the plugin process sees the plaintext token for the duration of the call. Rules: keep it in memory only, never log, never persist, never forward to anything but the provider. Every lease is audited (plugin, user, account, purpose).
- This is trust-based protection, appropriate for bundled/operator-approved plugins (ADR-0004 §7). A strict variant B (Core performs provider HTTP calls or an egress proxy injects the token) remains a future option for untrusted plugins.
- Revocation/expiry states exist for every credential (`ACTIVE`, `EXPIRING`, `EXPIRED`, `REVOKED`, `REAUTH_REQUIRED`).
- Plaintext secrets are never returned to the BFF, the browser, or any plugin descriptor.

### 4. Declarative UI

- On load, a plugin returns a **descriptor** (`Describe`): display name, icon (embedded, size-limited), connect flow type (`OAUTH2_REDIRECT | FORM | NONE`), settings schema, **post options schema**, media rules (MIME types, count, size, aspect limits) and caption limits.
- Schemas use a **restricted JSON-Schema subset**: `string` (with `enum`, `maxLength`, `pattern`), `integer`, `number`, `boolean`, `array` of those, nested `object` limited to depth 2. Core validates the subset at registration.
- The **web frontend owns the composer** (caption, media, schedule, account) and renders provider-specific fields from the schema. Core validates the final post against the schema and additionally calls the plugin's `ValidatePost` for rules a schema cannot express.
- Plugin-supplied strings are untrusted: rendered as escaped text only. No plugin JavaScript/HTML in the browser in v1. Iframe-based plugin UI is deferred (Phase C).

### 5. Publishing contract

- Core owns **posts**, **jobs**, **attempts** and the state machine (`SCHEDULED → RUNNING → SUCCEEDED | RETRY_WAIT | FAILED | OUTCOME_UNKNOWN | CANCELLED`).
- The plugin implements `Publish(job_id, attempt_id, idempotency_key, account, post, checkpoint?)` and returns one **outcome class**: `PUBLISHED`, `RETRYABLE_FAILURE`, `RATE_LIMITED`, `AUTH_FAILURE`, `PERMANENT_FAILURE`, or `UNKNOWN`. It may supply `retry_after`, an external ID/URL, and a safe, user-presentable error message.
- **Checkpointing:** before an irreversible provider step, the plugin calls `CheckpointAttempt(opaque bytes)` (e.g. a created-but-not-yet-published media container ID). Core stores it and passes it back on retry or reconcile.
- **Reconcile:** after an ambiguous outcome, Core calls `Reconcile(job, checkpoint)`; the plugin answers `PUBLISHED(external_id)`, `NOT_PUBLISHED`, or `UNDECIDABLE`. Only `NOT_PUBLISHED` allows an automatic retry; `UNDECIDABLE` waits for the user.
- Core, not the plugin, decides retries, backoff, terminal states and user-visible job state. Plugins never schedule their own retries.
- Per-account recurring work (e.g. token refresh) is **declared in the manifest** (`tasks`), and **invoked by Core** with each account owner's call token. Plugins do not register timers at runtime.

### 6. Callbacks and media

- **OAuth callback:** generic BFF route → Core `accounts.complete_connect` → plugin `HandleCallback` (ADR-0002 §5). Core generates and validates the `state` (single-use, bound to the session user, short TTL). Plugins never see the browser session.
- **Media:** Core stores media (local volume behind `MediaStorage`). A plugin gets media either as a **stream** (`OpenMedia`) or as a **short-lived signed public URL** (`CreatePublicMediaUrl`) — the latter is what Instagram needs. Tokens are unguessable, expiring and revocable; Core validates every request.

## Consequences

- Removes an entire class of risk and work: plugin DDL, per-plugin migrations, `search_path` handling, iframe bridges, plugin-side scheduling.
- Plugin authors write a small set of gRPC handlers and call a small Host API; the web frontend needs no plugin-specific code.
- The Instagram plugin can be built without any further infrastructure change if the Host API covers: storage, account upsert, credential store/lease, media URL, checkpoint, audit.
- Trade-off: plugins can see leased plaintext tokens — documented, audited, limited by the trust model.
- Trade-off: JSON-Schema-driven forms are less flexible than custom plugin UIs; acceptable for v1 and extendable via new descriptor field types (additive, versioned).

## Alternatives considered

- **Schema per plugin with plugin migrations:** more power than needed; reintroduces SQL identifier and `search_path` risks.
- **`secrets.use` with Core making all provider calls:** strongest, but turns Core into an HTTP client for every provider and defeats the plugin model.
- **Plugin-initiated user context (plugin passes a user ID):** rejected; impersonation by construction.
- **Iframe plugin UIs:** deferred; large surface (CSP, sandbox, postMessage) for no benefit to the first provider.
