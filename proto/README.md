# proto/ — Contracts (single source of truth)

All inter-process contracts of PostFlowX (gRPC + Protocol Buffers). Decision: ADR-0003 / OD-16.

```text
proto/postflowx/
  common/v1/common.proto      shared types (CallContext)
  plugin/v1/plugin.proto      Core → plugin  (PluginService)
  host/v1/host.proto          plugin → Core  (HostService)
  watchdog/v1/watchdog.proto  Core → Watchdog control API
  core/v1/…                   web → Core API (added in M0.3 / M5+)
```

**Status:** drafts. They mirror the sketches in `docs/protocol/IPC_PROTOCOL.md` and compile with `protoc`. Milestone **M0.3** finalizes them and adds the `buf` configuration; from then on this directory wins over the sketches in the documentation.

## Rules

- Package = `postflowx.<area>.v<major>`; the major version is part of the package name.
- Only additive changes inside a major version (new fields/RPCs/enum values). `buf breaking` runs against the previous release tag in this repository's CI.
- The contract version **is the deploy-repository tag** (the release bundle). Contracts and component versions cannot drift apart.
- Consumers (`postflowx-server`, `postflowx-web`, `postflowx-plugin-sdk`, `postflowx-plugin-instagram`) pin a deploy-repo tag or commit and fetch **only `proto/`** (sparse checkout, submodule or sync script — chosen in M1.1). Generated code is never committed and never hand-edited.

## Compile check (draft stage)

```bash
cd proto && mkdir -p /tmp/out
python3 -m grpc_tools.protoc -I. --python_out=/tmp/out --grpc_python_out=/tmp/out \
  postflowx/common/v1/common.proto postflowx/plugin/v1/plugin.proto \
  postflowx/host/v1/host.proto postflowx/watchdog/v1/watchdog.proto
```
