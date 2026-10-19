# Plugin Specification — Initial Contract

**Status:** Baseline for a reference plugin. Public third-party distribution is a later security milestone.

## 1. Plugin model

A plugin consists of:

- A manifest.
- Backend code running outside the Core process.
- Optional frontend assets rendered in an isolated context.
- Versioned data migrations, if needed.
- Tests and compatibility metadata.

A plugin can be installed globally by the installation administrator and may expose per-user instances/settings. Global installation does not mean every user automatically grants it access to their data.

## 2. Manifest fields

Conceptual example:

```json
{
  "manifest_version": "1",
  "id": "com.postflowx.instagram",
  "name": "Instagram",
  "version": "0.1.0",
  "api_compatibility": {
    "min": "1.0",
    "max_exclusive": "2.0"
  },
  "backend": {
    "protocol": "postflowx-ipc-v1",
    "health_operation": "health.read"
  },
  "frontend": {
    "entry": "index.html"
  },
  "capabilities_requested": [
    "social_accounts.manage",
    "media.read",
    "publishing.create",
    "publishing.read",
    "secrets.use"
  ],
  "data": {
    "migration_version": 1
  }
}
```

The manifest is descriptive input, not a security boundary. The Core validates fields, package contents, ID format, version compatibility and permission requests. The administrator approves the actual granted capabilities.

## 3. Identity and scopes

- Plugin ID is a stable reverse-DNS-like identifier.
- Plugin installation ID and plugin instance ID are distinct.
- A plugin instance belongs to an installation and may be scoped to one user or an explicitly shared resource.
- A plugin cannot select arbitrary user IDs and thereby impersonate a user.
- Core derives the actor and validates ownership for every operation.
- The permission check includes plugin identity, installation status, capability grant, user authorization, resource ownership and current state.

## 4. Capabilities

Use narrow verbs and resource types rather than broad labels like `database.admin` or `all_access`.

Examples:

- `social_accounts.read`
- `social_accounts.manage`
- `media.read`
- `media.create`
- `publishing.create`
- `publishing.read`
- `publishing.cancel`
- `secrets.use`
- `plugin_storage.read`
- `plugin_storage.write`

`secrets.use` means the plugin may ask Core to perform a specifically authorized operation using a secret; it does not mean it may retrieve the plaintext secret. Capability grants should be per plugin and scope, reviewable by the administrator, and revocable.

## 5. Data access and migrations

- Plugins do not receive a database connection string.
- Plugins use typed Core storage APIs; no arbitrary SQL endpoint exists.
- Plugin data is namespaced by plugin installation/instance and owner scope.
- Schema/table identifiers are generated from internal immutable IDs and validated against a strict allowlist.
- Migration packages are versioned and reviewed. Core runs migrations in a controlled context with bounded permissions.
- Migration failure must stop activation and leave a diagnosable state. Destructive migrations require explicit versioned steps and a recovery plan.
- Uninstall requires an explicit data disposition: retain/export/delete. No silent cascade deletion.
- PostgreSQL schemas are organizational and privilege boundaries only when grants/roles are correctly configured; Core authorization remains mandatory.

## 6. Frontend isolation

- Plugin UI is not injected directly into the main application DOM.
- Use an iframe with a restrictive sandbox and a distinct origin where deployment permits.
- Apply CSP and restrict script/network sources.
- Do not combine `allow-scripts` and `allow-same-origin` for untrusted plugin content without a documented security review.
- Use a narrow `postMessage` bridge; verify sender origin, source window, message schema and allowed action.
- The bridge exposes user-facing actions, not bearer tokens, raw secret values, database access or arbitrary Core RPC.
- Plugin UI is not trusted to enforce authorization; every action is validated by Core.

## 7. Runtime isolation

For each plugin runtime, where feasible:

- Non-root user.
- Read-only root filesystem; writable temporary area only where needed.
- Drop unnecessary Linux capabilities.
- No privileged mode, host PID/network namespace, host mounts or Docker socket.
- CPU, memory, process and request limits.
- Restrictive egress policy where feasible.
- No database credentials.
- Explicit health/readiness protocol and bounded shutdown.
- Pinned runtime image and package digest.

These are defense-in-depth controls. They do not make arbitrary third-party code risk-free.

## 8. Lifecycle states

`DISCOVERED` → `VALIDATING` → `INSTALLED` → `STARTING` → `READY`

Failure paths:

- `INVALID` — manifest/package invalid.
- `INCOMPATIBLE` — API/runtime version unsupported.
- `START_FAILED` — process failed to start.
- `UNHEALTHY` — repeated health checks failed.
- `DISABLED` — intentionally disabled.
- `UPDATING` — controlled update in progress.
- `UNINSTALL_PENDING` — data disposition/cleanup incomplete.

A plugin is not advertised as usable until it is `READY`. Failed startup must not leave half-created registry state or run migrations repeatedly without tracking.

## 9. Package updates and trust

MVP: administrator enables only packages from the controlled deployment bundle or an explicitly configured trusted source. No automatic installation of arbitrary remote code.

Later public distribution requires:

- Package digest/signature verification and publisher identity.
- Reviewable requested permission changes.
- Compatibility checks.
- Staged upgrade and rollback/forward recovery.
- Migration validation and backup policy.
- Revocation process for compromised packages.
- Security reporting and supported-version policy.
