# ADR-0003: Initial Technology Stack

- **Status:** Proposed baseline — **revision 2** (2026-10-22); validated by the M0.2 spike gate
- **Date:** 2026-10-20 (revised 2026-10-22)

## Context

PostFlowX needs a maintainable multi-process server (ADR-0004), a thin browser-facing BFF, an interactive frontend and a versioned cross-process contract. The server owns business logic, authorization, durable job state and all database access. The maintainer wants to write the server code personally and learn from it.

## Decision

1. **Server (`postflowx-server`): C++20.** Binaries in one image: `postflowx-watchdog` (PID 1), `postflowx-gateway`, `postflowx-core`, plus plugin executables. They are separate OS processes that talk gRPC (ADR-0004).
2. **IPC: gRPC + Protocol Buffers.** Unix domain sockets inside the server container; TCP with mutual TLS between web and server. The `.proto` files live in the `proto/` directory of the deploy repository and are the single source of truth for all contracts (see "Repositories").
3. **Web BFF: TypeScript + Fastify.** gRPC client via `@grpc/grpc-js` with generated typed stubs (generator is fixed in M0.2).
4. **Frontend: TypeScript + React + Vite**, TypeScript `strict`. Runtime validation at every trust boundary (types are not validation).
5. **Database: PostgreSQL** (one `core` schema, Core-owned; ADR-0005).
6. **Deployment: Docker Compose** on a single Linux host.

### Proposed libraries and tooling (validated in M0.2, recorded in OD-19)

| Area | Proposal | Notes |
| --- | --- | --- |
| Build | CMake + Ninja | reproducible, pinned toolchain in the build image |
| C++ dependencies | vcpkg or Conan (manifest mode, locked) | decided by the spike; must work offline in CI |
| RPC | gRPC C++ + protobuf | generic (opaque-bytes) proxying for the Gateway to be verified |
| Crypto | libsodium | Argon2id password hashing, XChaCha20-Poly1305 AEAD, CSPRNG |
| PostgreSQL client | libpq (thin RAII wrapper) or libpqxx | prepared statements only; decided in M0.4/M5 |
| Migrations | own minimal runner: ordered, checksummed `.sql` files | decided in M5 |
| Logging | structured JSON logs (spdlog or equivalent) | secret redaction by construction, not by regex alone |
| Tests (C++) | GoogleTest; sanitizers (ASan/UBSan/TSan) in CI | |
| Static analysis | clang-tidy, `-Wall -Wextra -Werror`, cppcheck optional | |
| Proto governance | `buf` (lint + breaking-change detection) | gate for `proto/` |
| Web tests | Vitest; Playwright for end-to-end later | |

## Validation gate (M0.2)

C++ with gRPC, mTLS and a multi-process layout is the highest-risk part of the stack for a one-person project. Before M1 starts, a time-boxed spike must demonstrate **all** of the following in CI:

1. Reproducible container build of a C++ binary with gRPC + protobuf + libsodium + libpq from a pinned toolchain.
2. gRPC over a Unix domain socket and gRPC over TCP with mutual TLS (C++ server ↔ Node client).
3. Whether the Gateway can proxy messages generically (opaque bytes) while enforcing a method allowlist, size limits and deadlines; otherwise typed forwarding handlers.
4. Whether the caller can be identified on a Unix socket (socket-directory permissions as the primary mechanism; peer credentials only if the library exposes them).
5. Watchdog-as-PID-1 launching a child under another UID, with rlimits, `no_new_privs`, and a health check.
6. Secrets distribution: a plugin UID cannot read secret files or other processes' `/proc` entries (OD-15).

**If the gate fails** (e.g. build/dependency effort is out of proportion), the stack is revisited via an updated ADR **before** milestone work begins. Candidate alternatives are recorded, not pre-judged: Go or Rust for the server (gRPC and static binaries are first-class there), keeping all contracts unchanged because they are language-neutral Protocol Buffers.

## Rationale

- C++ matches the maintainer's goal of writing and understanding the server code, with static typing and control over processes and memory. Its cost (toolchain, dependency management, memory-safety discipline for a component that holds credentials) is accepted *only if* the gate above passes and the safety measures below are in place.
- gRPC/Protobuf gives typed, language-neutral contracts with generated clients for C++ and TypeScript — this is what allows plugins and the BFF to be written independently.
- Fastify keeps the BFF thin; React/Vite fit the dashboard, composer and calendar UI.

## Consequences and constraints

- C++ safety measures are part of M2, not optional: sanitizers and static analysis block merges; all input crossing a trust boundary is validated; no raw owning pointers; no manual SQL string building.
- Generated protobuf code is **not hand-edited**; the `proto/` directory is versioned together with the deploy repository and every consumer pins a deploy-repo tag or commit.
- Plugin binaries must be built against the server's pinned base image (same libc/ABI) or statically linked (OD-14).
- Do not add a second public HTTP entry point to the server. The web BFF is the only public application entry point.

## Repositories

| Repository | Content |
| --- | --- |
| `postflowx-deploy` | this repo: Compose, scripts, docs, ADRs, release bundle manifest, **`proto/` (all `.proto` files, `buf` config, contract-test fixtures)** |
| `postflowx-server` | watchdog, gateway, core; plugin host services |
| `postflowx-web` | React frontend + Fastify BFF |
| `postflowx-plugin-sdk` *(from M9)* | C++ SDK, reference plugin, plugin test harness |
| `postflowx-plugin-instagram` *(Phase B)* | the Instagram plugin |

`proto/` is consumed by the other repositories at a pinned deploy-repo tag or commit; only the `proto/` directory is fetched (sparse checkout or sync script, OD-16). Generated code is not committed. Because the release bundle is a deploy-repo tag, the contract version and the component versions cannot drift apart.

## Acceptance

Accepted when the M0.2 gate passes, the toolchain builds in CI (M2), the proto contracts pass the M0.3 design gate and the remaining implementation-specific choices are recorded without contradicting architecture, IPC protocol, feature list, PRD or roadmap.
