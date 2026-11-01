# Contracts — IPC rules and plugin spec

**Message definitions live in `proto/postflowx/**.proto`** (source of truth; they are drafts today — finalize them while building Steps 1, 3 and 8; they already compile with `protoc`). This file holds the rules around them. Structure: [`ARCHITECTURE.md`](ARCHITECTURE.md).

## 1. Services
| Service (package) | Direction | Used by |
|---|---|---|
| `postflowx.core.v1.*` | web → Gateway → Core | BFF (add per step: Health S1/S4, Auth S5, Users S5, Plugins S7, Accounts/Media/Posts S8–10, Jobs S9) |
| `postflowx.plugin.v1.PluginService` | Core → Gateway → plugin | `Describe, BeginConnect, HandleCallback, ValidatePost, Publish, Reconcile, RunTask` |
| `postflowx.host.v1.HostService` | plugin → Gateway → Core | storage, accounts, credentials, media, checkpoint, audit (see §4) |
| `postflowx.watchdog.v1.WatchdogControl` | Core → Watchdog | `ListProcesses, StartPlugin, StopPlugin, RestartPlugin` |
| `grpc.health.v1.Health` | Watchdog → each process | on `/run/postflowx/health/<name>.sock`, status only |

## 2. Transport, identity, gateway rules
- **web↔server:** gRPC/TCP/**mTLS** (internal CA from `init-secrets.sh`, server SAN `server`, client `CN=postflowx-web`); `production` mode refuses to start without it. **Inside server:** gRPC over Unix sockets, access by file permissions.
- **Identity chain:** Gateway authenticates transport (cert or plugin socket), **strips every client `x-pfx-*`**, sets `x-pfx-caller-kind` (`web|plugin|core`), `x-pfx-caller-id` (`postflowx-web | plugin:<id> | core`), `x-pfx-request-id`. Core only listens on a Gateway-only socket. **User identity is never read from a caller-controlled field:** web sends an opaque session token (`x-pfx-session`), plugins send a **call token** (`ctx.call_token`). Core re-authorizes everything.
- **Method allowlist (deny by default):** `web` → `core.v1.*`; `plugin` → `host.v1.HostService/*` only; `core` → `plugin.v1.PluginService/*` toward the named plugin.
- **Limits (defaults):** message 4 MiB (media: chunks of 64 KiB); deadline 30 s unary, `Publish` 120 s default / 10 min max; per-caller and per-plugin rate + concurrency limits. Invalid identity, unknown major version or malformed metadata → rejected.
- **Versioning:** package carries the major (`…v1`); only additive changes inside a major (new optional fields/RPCs/enum values); breaking = new `v2` served in parallel. Plugins declare `api_compatibility`; Core refuses incompatible ones. Contract version = deploy-repo tag.

## 3. Call tokens (user context for plugins)
Core-initiated calls (connect, callback, validate, publish, reconcile, per-account tasks) carry an opaque random token (256-bit, stored hashed) bound to *(plugin, user, purpose, optional job/account, expiry ≤ call deadline)*. Every user-scoped Host API call must return it. Core checks token validity/revocation, that the token's plugin equals the Gateway-assigned identity, and that the resource is in scope. Disabling a plugin or revoking a grant invalidates its tokens. Plugin-global operations need only plugin identity + grant.

## 4. Host API (plugin → Core)
| Group | Operations | Notes |
|---|---|---|
| Storage | `StorageGet/Put/Delete/List` | scope `USER` (owner from token) or `PLUGIN`; `Put` with `expected_version`; value ≤ 256 KiB; per-plugin quota |
| Accounts | `UpsertAccount, DeleteAccount, SetAccountStatus` | only for the token's user + this plugin |
| Credentials | `StoreCredential, LeaseCredential` | lease returns plaintext + `lease_expires_at`; audited (plugin, user, account, purpose) |
| Media | `OpenMedia` (stream), `CreatePublicMediaUrl` | only media of the current job; TTL capped by Core |
| Jobs | `CheckpointAttempt` | opaque bytes, size-limited, job-scoped token only |
| Audit | `AppendAudit` | Core sets actor/plugin; no secrets |

## 5. Publishing semantics
`Publish(job_id, attempt_id, idempotency_key, account, post, checkpoint?)` → outcome `PUBLISHED | RETRYABLE_FAILURE | RATE_LIMITED | AUTH_FAILURE | PERMANENT_FAILURE | UNKNOWN` + optional `external_id/url`, stable `error_code`, safe user-presentable `error_message`, `retry_after`. Plugins must be **idempotent per `attempt_id`**, honor the deadline, never log secrets. Core decides retries/backoff/terminal states (default backoff 1 min → 5 min → 30 min → 2 h, max 5 attempts, configurable); plugins never schedule retries. `Reconcile(job, checkpoint)` → `PUBLISHED | NOT_PUBLISHED | UNDECIDABLE`. Core **never** auto-retries after a timeout/crash/`UNAVAILABLE` that occurred *after dispatch*.

## 6. Errors and idempotency
Standard gRPC status + `google.rpc.ErrorInfo` (`domain="postflowx"`, stable `reason`). No stack traces, SQL errors, secrets or paths to untrusted callers.
| Status | Reasons (examples) | Retry |
|---|---|---|
| `INVALID_ARGUMENT` | `VALIDATION_ERROR` | no |
| `UNAUTHENTICATED` | `SESSION_INVALID`, `SERVICE_IDENTITY_UNKNOWN` | no |
| `PERMISSION_DENIED` | `FORBIDDEN`, `CAPABILITY_NOT_GRANTED`, `CALL_TOKEN_INVALID` | no |
| `NOT_FOUND` | absent **or hidden** | no |
| `ABORTED`/`FAILED_PRECONDITION` | `CONFLICT`, `VERSION_MISMATCH`, `STATE_INVALID` | after re-read |
| `RESOURCE_EXHAUSTED` | `RATE_LIMITED`, `QUOTA_EXCEEDED` | later |
| `DEADLINE_EXCEEDED` | *may have completed* | query state first |
| `UNAVAILABLE` | `NOT_READY`, `DEPENDENCY_DOWN` | reads yes; mutations: query state first |
| `UNIMPLEMENTED` | `UNSUPPORTED_PROTOCOL` | no |
| `INTERNAL` | no details | no |

Mutations where a duplicate would do harm take an **idempotency key**; Core stores `(caller, key) → result` for a bounded time. A timed-out request **may have completed** — query before repeating. The Gateway never silently replays non-idempotent calls.

## 7. Plugin package and manifest
```text
<id>/<version>/  manifest.json · bin/postflowx-plugin-<name> · assets/icon.svg (optional) · sha256sums (written by install CLI)
```
```json
{ "manifest_version": 1, "id": "com.postflowx.instagram", "name": "Instagram", "version": "0.1.0",
  "provides": ["publisher"], "api_compatibility": { "min": "1.0", "max_exclusive": "2.0" },
  "entrypoint": { "executable": "bin/postflowx-plugin-instagram" },
  "capabilities_requested": ["storage.read","storage.write","accounts.manage","credentials.store","credentials.lease","media.read","media.public_url","audit.append"],
  "callbacks": ["oauth"],
  "tasks": [{ "name": "refresh_account", "scope": "account", "interval": "24h" }],
  "network": { "egress_hosts": ["graph.facebook.com", "graph.instagram.com"] },
  "resources": { "memory_mb": 256, "max_processes": 16 } }
```
- The manifest is **input, not a security boundary.** Core validates strictly (reverse-DNS lowercase ID, version syntax, known capabilities, task definitions, sizes; unknown fields rejected). Requested capabilities are only requests — the **admin grants** (reviewable, revocable, audited). Unknown capability = fail closed.
- `egress_hosts` is informational in v1 (not enforced: shared network namespace). `resources` applied as rlimits best-effort. `tasks` are invoked by Core with each account owner's call token; plugins register no timers.
- **Capabilities (v1):** `storage.read/write`, `accounts.manage`, `credentials.store`, `credentials.lease`, `media.read`, `media.public_url`, `audit.append`. No "all access", no DB capability. Kind `publisher` only; later `ai_text`.

## 8. Plugin runtime rules
- **Isolation (Watchdog applies):** own UID/GID, no capabilities, `no_new_privs`, non-dumpable, clean env, private tmpfs, rlimits (`NPROC, NOFILE, memory, CORE=0`), private socket dir, read-only plugin dir. Not provided in v1: egress filtering, DB-network isolation (auth only), protection from a malicious plugin with legitimately granted capabilities.
- **Trust levels:** `BUNDLED` (shipped in release) and `OPERATOR_APPROVED` run; `UNTRUSTED` does not (manifest inspection only). Grants are always explicit.
- **Declarative UI:** `Describe` returns name, icon (SVG sanitized, size-limited), connect flow (`OAUTH2_REDIRECT | FORM | NONE`), settings schema, **post options schema**, media rules, caption limit, API version. Schemas = restricted JSON-Schema subset (`string` with `enum/maxLength/pattern`, `integer`, `number`, `boolean`, arrays of those, nested `object` depth ≤ 2), validated by Core at registration. Frontend owns the composer; Core validates the final post against the schema + `ValidatePost`.
- **Data:** only via the storage API; uninstall requires explicit retain/delete.
- **Updates (v1):** operator installs a new version with the CLI; admin switches; capability changes need renewed approval. No remote auto-install.
- **SDK (`postflowx-server/sdk/`, Step 8e):** generated stubs, service skeleton, call-context handling, Host API client, health service; **demo plugin** with failure injection; manifest validator.

## 9. Contract tests (add as you build)
Valid call; no/invalid cert; wrong caller kind; forged `x-pfx-*`; oversized message; expired deadline; unsupported version; expired/replayed/wrong-plugin/missing call token; plugin calling a core method; malformed bytes.
