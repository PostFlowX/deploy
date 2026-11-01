# proto/ — contracts (source of truth)

gRPC + Protocol Buffers for all inter-process calls. Rules and semantics: `docs/CONTRACTS.md`.

```text
proto/postflowx/
  common/v1/common.proto      CallContext
  plugin/v1/plugin.proto      Core → plugin (PluginService)
  host/v1/host.proto          plugin → Core (HostService)
  watchdog/v1/watchdog.proto  Core → Watchdog
  core/v1/…                   web → Core (add per step: health S1/S4, auth S5, …)
```

- **Drafts** that compile with `protoc`; finalize while building (Steps 1, 3, 8). Contract freeze = end of Step 8.
- Package = `postflowx.<area>.v<major>`; only additive changes inside a major version.
- Version = deploy-repo tag. Other repos pin it in `PROTO_REF` and fetch only `proto/`. **Never commit generated code or hand-edit it.**
- Optional: `buf lint` / `buf breaking` once the files settle (not required for v0.1).

Compile check: `mkdir -p /tmp/out && python3 -m grpc_tools.protoc -I. --python_out=/tmp/out --grpc_python_out=/tmp/out postflowx/*/v1/*.proto`
