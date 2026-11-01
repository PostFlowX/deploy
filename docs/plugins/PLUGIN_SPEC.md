# Plugin Specification — Contract v1

**Status:** Proposed baseline — **revision 2** (2026-10-22). Normative companions: ADR-0004 (hosting), ADR-0005 (data, credentials, UI, publishing), IPC_PROTOCOL (wire contract). Public third-party distribution is a later security milestone (Phase C).

## 1. Plugin model

A plugin is:

- a **manifest** (`manifest.json`),
- a **native executable** that serves the `PluginService` over a Unix socket and calls the Core **Host API**,
- optional static assets (e.g. an icon) referenced by the manifest,
- tests and compatibility metadata (SDK test harness).

A plugin is installed **globally** by the operator and enabled/granted by the installation admin. One process per plugin ID serves **all** users; user context arrives only through Core-issued call tokens (ADR-0005 §1). A plugin never receives the browser session, database credentials, key material or the Docker socket.

Plugin kinds (`provides`): `publisher` in v1. Later: `ai_text` (text generation provider), others as needed.

## 2. Package layout

```text
<id>/<version>/
  manifest.json
  bin/postflowx-plugin-<name>       # entry point (regular file, executable)
  assets/icon.svg                   # optional, size-limited
  sha256sums                        # written by the install CLI; pins every file
```

Installed under `/var/lib/postflowx/plugins/`, mounted **read-only** into the running server. The operator installs with `postflowx-plugin install <package>` (one-off container). The CLI validates the manifest, checks path safety, computes and records hashes; Core stores the pinned hash of the entry point. The Watchdog executes only that hash-verified file (ADR-0004 §4).

## 3. Manifest

```json
{
  "manifest_version": 1,
  "id": "com.postflowx.instagram",
  "name": "Instagram",
  "version": "0.1.0",
  "provides": ["publisher"],
  "api_compatibility": { "min": "1.0", "max_exclusive": "2.0" },
  "entrypoint": { "executable": "bin/postflowx-plugin-instagram" },
  "capabilities_requested": [
    "storage.read",
    "storage.write",
    "accounts.manage",
    "credentials.store",
    "credentials.lease",
    "media.read",
    "media.public_url",
    "audit.append"
  ],
  "callbacks": ["oauth"],
  "tasks": [
    { "name": "refresh_account", "scope": "account", "interval": "24h" }
  ],
  "network": {
    "egress_hosts": ["graph.facebook.com", "graph.instagram.com"]
  },
  "resources": { "memory_mb": 256, "max_processes": 16 }
}
```

Rules:

- The manifest is **descriptive input, not a security boundary**. Core validates ID format (reverse-DNS, lowercase, charset-restricted), version syntax, compatibility range, capability names, task definitions and sizes. Unknown fields are rejected.
- `capabilities_requested` are requests; the **admin grants** the actual set (reviewable, revocable, audited). Unknown capabilities fail closed.
- `network.egress_hosts` is **informational in v1** (shown during permission review, used for documentation and future enforcement). It is not enforced because plugins share the container network namespace (T2).
- `resources` are applied as rlimits/limits best-effort by the Watchdog.
- `tasks` are declared here and **invoked by Core**; plugins register no timers at runtime.

## 4. Identity, scopes and call tokens

- Plugin ID is a stable reverse-DNS identifier. Installation, version and *process* are distinct concepts; the Gateway assigns the identity `plugin:<id>` from the socket a call arrived on.
- All user-scoped work is initiated by Core with a **call token** bound to *(plugin, user, purpose, optional job/account, expiry)*. The plugin attaches it to every user-scoped Host API call. Core rejects calls where token, plugin identity or requested resource do not match.
- Plugin-global operations (e.g. plugin-global storage) require only plugin identity and a granted capability.
- A plugin cannot choose a user ID, cannot call admin operations and cannot act for a user outside an active Core-initiated call.

## 5. Capabilities (v1)

Narrow verbs and resource types; no `all_access`, no database capability.

| Capability | Allows |
|---|---|
| `storage.read` / `storage.write` | `Get/List` / `Put/Delete` in the plugin's own storage, scoped by call token (user) or plugin-global |
| `accounts.manage` | `UpsertAccount`, `DeleteAccount`, update status for accounts of the call-token user belonging to this plugin |
| `credentials.store` | `StoreCredential` for such an account |
| `credentials.lease` | `LeaseCredential` — returns plaintext for the lease duration (audited; see ADR-0005 §3) |
| `media.read` | `OpenMedia` stream for media referenced by the current job/call |
| `media.public_url` | `CreatePublicMediaUrl` — short-lived signed URL for media in the current job |
| `audit.append` | append plugin-scoped audit events (Core sets actor/plugin; plugin cannot forge system events) |

`publisher` plugins additionally use `CheckpointAttempt` implicitly (no extra capability; only valid within a job-scoped call token).

## 6. Plugin service (Core → plugin)

Implemented by the plugin; invoked via the Gateway. Exact messages: `proto/` (M0.3); sketch in IPC_PROTOCOL.

| Method | Purpose |
|---|---|
| `Describe` | descriptor: name, icon, connect flow, settings schema, **post options schema**, media rules, caption limits, API version |
| `BeginConnect` | start a connection flow; returns provider authorization URL (embedding Core's `state`) |
| `HandleCallback` | complete the flow with the provider's callback parameters |
| `ValidatePost` | provider-specific validation beyond the schema |
| `Publish` | perform the publication for one attempt; returns an outcome class |
| `Reconcile` | determine whether a possibly-published post exists |
| `RunTask` | execute a manifest-declared task for one account |
| *(standard)* `grpc.health.v1.Health` | liveness/readiness for the Watchdog |

Plugins must be **idempotent per `attempt_id`/`idempotency_key`**, must respect the gRPC deadline, must not block shutdown beyond the grace period, and must never log secrets or tokens.

## 7. Host API (plugin → Core)

| Group | Operations |
|---|---|
| Storage | `StorageGet`, `StoragePut(expected_version)`, `StorageDelete`, `StorageList` |
| Accounts | `UpsertAccount`, `DeleteAccount`, `SetAccountStatus` |
| Credentials | `StoreCredential`, `LeaseCredential` |
| Media | `OpenMedia` (stream), `CreatePublicMediaUrl` |
| Jobs | `CheckpointAttempt` |
| Audit | `AppendAudit` |

Limits (configurable): storage value ≤ 256 KiB, per-plugin storage quota, request size caps, per-plugin rate/concurrency limits at the Gateway.

## 8. Declarative UI

Plugins ship **no browser code in v1**. The frontend renders from the descriptor (ADR-0005 §4): connection card (type and button), plugin settings form, provider-specific post options in the composer, media/caption constraints with live validation. Schemas are a restricted JSON-Schema subset validated by Core at registration. All plugin strings are untrusted text (escaped on render). Core remains the authority for validation; UI checks are convenience.

## 9. Data

Plugins store data only through the storage API (typed key/value, JSONB, Core-owned table). **No database connection, no SQL, no DDL, no plugin migrations, no plugin schemas.** Key and collection names follow a strict charset. On uninstall the admin must choose **retain / export / delete**; there is no silent cascade deletion.

## 10. Runtime isolation (v1, per plugin process)

Applied by the Watchdog (ADR-0004 §3): dedicated UID/GID; all capabilities dropped; `no_new_privs`; non-dumpable; cleared environment; private tmpfs temp dir; rlimits (`NPROC`, `NOFILE`, memory, `CORE=0`); private socket directory; read-only plugin directory; no access to Core state, media volume or secrets. Optional, feature-detected: Landlock filesystem rules, seccomp profile.

Not provided in v1 (documented residual risk): network isolation from PostgreSQL (blocked by authentication only), egress filtering, protection against a malicious plugin with legitimately granted capabilities.

## 11. Trust levels (simplified from the earlier T0–T3 × E0–E3 draft)

| Level | Meaning | Runs in v1? |
|---|---|---|
| `BUNDLED` | shipped in the release bundle, built by the project's release process | yes |
| `OPERATOR_APPROVED` | installed by the operator and explicitly approved in the admin UI | yes |
| `UNTRUSTED` | unreviewed third-party code | **no** (inspect manifest only) |

Trust does not grant capabilities by itself; grants are always explicit. Execution levels E0–E3 from the earlier draft collapse to one level in v1 (process-in-container, "E2-lite"). Container-per-plugin ("E3") is the planned path for untrusted plugins and requires a new ADR.

## 12. Lifecycle states

`DISCOVERED → VALIDATING → INSTALLED → ENABLED → STARTING → READY`

Failure and administrative states:

- `INVALID` — manifest/package invalid or hash mismatch.
- `INCOMPATIBLE` — API/runtime version unsupported.
- `START_FAILED` — process failed to start or to pass its first health check.
- `UNHEALTHY` — repeated health-check failures.
- `CRASH_LOOP` — restart limit exceeded; manual action required.
- `DISABLED` — intentionally disabled (capabilities revoked, call tokens invalidated).
- `UPDATING` — controlled version switch in progress.
- `UNINSTALL_PENDING` — data disposition not yet chosen/completed.

A plugin is not advertised as usable until `READY`. Failed startup leaves no half-created registry state. Revoking a capability or disabling a plugin takes effect without restarting the platform (Core invalidates grants/call tokens; the Watchdog stops the process).

## 13. Updates and trust (v1 and later)

**v1:** the operator installs a new version with the CLI; the admin switches the active version in the UI; the old version remains available for rollback; capability changes require renewed admin approval. No automatic remote installation.

**Later (Phase C), before any third-party distribution:** package signatures and publisher identity, UI upload, staged updates with rollback, revocation of compromised packages, security reporting and a supported-version policy.

## 14. Developer experience (SDK, from M9)

`postflowx-plugin-sdk` provides: generated stubs, a C++ helper library (service skeleton, call-context handling, Host API client, health service), a **reference plugin** (a "demo publisher" that simulates publishing, supports failure injection and `OUTCOME_UNKNOWN` cases), a local test harness that runs plugin ↔ fake Core, and manifest validation tooling.
