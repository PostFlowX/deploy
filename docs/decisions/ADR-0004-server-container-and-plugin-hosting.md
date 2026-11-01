# ADR-0004: Multi-Process Server Container, Watchdog as PID 1, Plugin Hosting

- **Status:** Proposed baseline (new, 2026-10-22)
- **Supersedes:** ADR-0001 rev. 1 items 4–6, ADR-0003 rev. 1 item 1 wording
- **Related:** ADR-0001, ADR-0005, THREAT_MODEL (T2, T13–T16), PLUGIN_SPEC

## Context

The server must host long-running infrastructure processes (gateway, core), supervise them, and run plugins that are developed in separate repositories. Three constraints shape the design:

1. **Least privilege between processes.** Only Core may hold database credentials and the encryption key.
2. **Plugins are installed into the server container** (not into separate containers) and are managed from the web UI.
3. **One-person project.** Every additional boundary or privileged component must pay for itself.

## Decision

### 1. Processes in the server container

| Process | Binary | UID (proposal) | Role |
|---|---|---|---|
| Watchdog | `postflowx-watchdog` | root, **minimal capabilities** (see §3) | PID 1; spawns, supervises, restarts, health-observes; distributes secrets; reports aggregate health |
| Gateway | `postflowx-gateway` | `10010` | Only router and identity authority; authenticates callers; method allowlist, limits, deadlines, correlation IDs. No DB access, no key material |
| Core | `postflowx-core` | `10020` | Business logic, authorization, jobs, secrets, the only DB client |
| Plugin *n* | `postflowx-plugin-<id>` | pool `20000+` (one UID per plugin ID, assigned by Watchdog) | Provider integration; no DB credentials, no keys, no Docker |

All inter-process communication is **gRPC**. Inside the container it runs over **Unix domain sockets** under `/run/postflowx/` (tmpfs); between `web` and `server` it runs over TCP with **mutual TLS**.

### 2. Start order, restart and shutdown

1. Watchdog starts, prepares tmpfs directories/sockets and re-homes secrets (§5), then starts **Core**.
2. Core connects to PostgreSQL, applies migrations, then reports *ready*.
3. Watchdog starts **Gateway**; when ready, the container is *healthy*.
4. Core tells the Watchdog (control socket, §4) which plugins are enabled; the Watchdog starts them. A failing plugin makes the stack **degraded**, never **unhealthy**.
5. Crashed processes are restarted with exponential backoff and a crash-loop limit (e.g. 5 failures in 5 minutes → `CRASH_LOOP`, stop restarting, surface in admin UI). Core/Gateway crash loops make the container unhealthy so that Docker's restart policy takes over.
6. **Shutdown (SIGTERM):** Core stops claiming jobs and drains in-flight attempts (bounded) → plugins are asked to stop → Gateway stops → Core exits → Watchdog exits. Compose `stop_grace_period` ≥ the sum of the bounded waits.
7. If the Watchdog itself dies the container dies; Docker restarts it. The Watchdog is intentionally small and has no network access.

### 3. Watchdog privileges

- Starts as root with `cap_drop: ALL` plus only `SETUID`, `SETGID`, `CHOWN`, `KILL`, `DAC_READ_SEARCH` (the last one only to read `0400` secret files owned by the host user). Container flags: `read_only`, `no-new-privileges`, `pids_limit`, memory limit.
- Every child is started with: dedicated UID/GID, **all capabilities dropped** (bounding and ambient sets cleared), `no_new_privs`, `PR_SET_DUMPABLE=0`, cleared environment (explicit allowlist), own `cwd`, private `tmpfs` temp dir (mode `0700`), `setrlimit` (`NPROC`, `NOFILE`, `AS`/`DATA`, `CORE=0`).
- Optional hardening where the host kernel supports it (feature-detected, P1): Landlock filesystem restriction and a seccomp filter for plugin processes.
- The Watchdog has **no Docker access**, **no network listener** and no business logic.

### 4. Control interface

A gRPC service on `/run/postflowx/watchdog.sock`, accessible **only to the Core UID** (and the healthcheck CLI as root):

- `ListProcesses`, `GetHealth` (read-only status for the admin UI),
- `StartPlugin(plugin_id, version)`, `StopPlugin(plugin_id)`, `RestartPlugin(plugin_id)`.

`StartPlugin` is a **narrow runtime controller**, not a general process launcher. The Watchdog only executes a regular file located inside `/var/lib/postflowx/plugins/<id>/<version>/`, after verifying path containment (no traversal, no symlink escape), that the plugin ID/version match the manifest, and that the executable's SHA-256 matches the hash pinned at installation (`sha256sums`). It never accepts a command line or path from the caller.

### 5. Secret distribution inside the container

Compose delivers file secrets to `/run/secrets/*` with host-file permissions (`0400`, host user). Because Compose cannot reliably set per-file ownership for different processes (OD-15):

- The Watchdog (root + `DAC_READ_SEARCH`) reads them and writes **per-process copies** to `/run/postflowx/secrets/<process>/` (tmpfs, owner = that process UID, mode `0400`), then drops privileges. Core receives DB password and master key; Gateway receives the TLS server key and CA; plugins receive nothing.
- Plugin UIDs cannot read `/run/secrets/*`, `/run/postflowx/secrets/*`, Core's state directory, the media volume, or `/proc/<pid>/{environ,mem,fd}` of other processes. This is an **acceptance test** (M3, M13).
- Fallback if `/run/secrets` permissions behave differently on a platform: hand secrets to the Watchdog as environment variables or inherited FDs only (visible to root/same UID only). The decision and test are recorded in M1.2.

### 6. Plugin hosting model

- A plugin is a **native executable + manifest** (PLUGIN_SPEC). One process per enabled plugin ID; it serves all users and receives per-call user context from Core (ADR-0005, call tokens).
- **Installation (v1):** the operator installs a package onto the `plugins` volume with a one-off CLI container (`docker compose run --rm server postflowx-plugin install <package>`), which validates the manifest and pins the SHA-256 of every file. The running server mounts the volume **read-only**. The web UI manages *enable/disable, capability grants, configuration, health and logs* — **not** upload of executables. UI upload with signature verification is deferred (OD-11, Phase C).
- **Plugin implementation language** is free in principle (contract = gRPC/Protobuf), but the artifact must run in the server image (static binary, or built against the pinned base image). The SDK targets C++ first (OD-14).
- Each plugin gets a private socket directory `/run/postflowx/plugins/<id>/` that only that plugin's UID and the Gateway UID may access. Plugin identity = *which socket the call arrived on*, enforced by filesystem permissions (kernel-enforced); peer-credential checks are an additional layer where available.

### 7. Trust model v1

- Allowed: **bundled** plugins (shipped in the release bundle) and **operator-approved** plugins (explicitly approved by the installation admin; the admin accepts responsibility).
- **Not supported:** untrusted third-party code. Process isolation here reduces blast radius and enforces the Core API boundary; it is **not** a sandbox against a hostile plugin (shared network namespace, shared kernel, shared egress).
- Residual risks that remain by design: a plugin can read credentials it legitimately leases (ADR-0005), can use the container's network egress, and can attempt network connections to PostgreSQL (blocked by authentication, not by network isolation).
- Moving to untrusted plugins requires a new ADR introducing container-per-plugin isolation, an egress policy and a narrowly scoped runtime controller.

### 8. Network exposure

The server container is attached to two networks: `backend` (internal, no internet; web, server, db) and `egress` (outbound only; needed because plugins call provider APIs). No ports are published from the server container. PostgreSQL is on `backend` only.

## Consequences

- **Good:** key and DB credentials are confined to one process (Core); a bug in Gateway/Watchdog/plugin does not expose them by itself. Plugin crashes are isolated and restartable; the container stays healthy.
- **Cost:** a small privileged supervisor must be written and tested (spawning, privilege drop, secrets re-homing, crash-loop logic). Scope is capped: static process list first (M3), dynamic plugins later (M8).
- **Cost:** Gateway is part of the trusted computing base because it assigns caller identity; it is kept tiny, has no secrets, and Core additionally validates plugin identity against call tokens.
- **Operational:** the image contains plugin runtimes' dependencies; upgrading the server image means re-validating plugin compatibility (compatibility matrix in the release bundle).

## Alternatives considered

| Alternative | Why not (now) |
|---|---|
| Everything in one process with modules | One memory-safety bug exposes keys everywhere; no plugin isolation |
| Plugins as `dlopen` libraries | In-process, ABI fragile, a plugin crash kills Core |
| One container per plugin | Needs Docker API access (runtime controller) and egress policy design; right answer for untrusted plugins, premature for v1 |
| Off-the-shelf supervisor (s6-overlay, supervisord) | Good for the static part, but dynamic plugin start with UID pools, hash verification and secret re-homing needs custom code anyway. Re-evaluated in OD-13 if the custom watchdog proves too costly |
| Threads instead of processes | No privilege separation |

## Required tests

Plugin UID cannot read Core secrets or `/proc` of other UIDs; plugin cannot authenticate to PostgreSQL; plugin cannot connect to another plugin's socket; Watchdog refuses paths outside the plugin directory and hash mismatches; crash loop detection; graceful shutdown ordering; container remains healthy when a plugin fails.
