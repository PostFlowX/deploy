# ADR-0003: Initial Technology Stack

- **Status:** Proposed baseline; validate during engineering foundation and IPC contract milestones
- **Date:** 2026-10-20

## Context

PostFlowX needs a maintainable server, a thin browser-facing BFF, and an interactive frontend. The server owns business logic, authorization, persistent job state and database access. The Web BFF owns browser-facing HTTP/session concerns and forwards typed operations to the server. The stack should support clear component boundaries, testability, containerized deployment and a versioned cross-component contract.

Existing PostAPI code is not required to choose the platform's foundational stack. Reusable Instagram integration logic will be evaluated when implementing the Instagram plugin (M12).

## Decision

Use the following initial technology baseline:

1. **Server:** C++20 for the `postflowx-server` process. Core, IPC Gateway and Watchdog are internal modules in that process.
2. **Preferred IPC contract:** gRPC with Protocol Buffers over the private Compose network. M0.3 must validate service authentication, deadlines, payload limits, error mapping, health reporting, compatibility and generated-code workflow before transport implementation is finalized.
3. **Web BFF:** TypeScript with Fastify for browser-facing HTTP/API routes, cookie/session transport, browser protections, request validation and typed forwarding.
4. **Frontend:** TypeScript with React for component-based UI and Vite for local development and production builds.
5. **Database:** PostgreSQL.
6. **Deployment:** Docker Compose for the initial single-host installation.

## Rationale

- C++ satisfies the desired server implementation approach and provides static typing and high runtime control.
- gRPC and Protocol Buffers provide typed service contracts and generated client/server interfaces across the C++ and TypeScript ecosystems.
- TypeScript allows the BFF and frontend to share language-level tooling while preserving their separate security and deployment boundaries.
- Fastify is a deliberately thin HTTP framework suitable for BFF responsibilities.
- React supports reusable UI components for the planned dashboard, publishing calendar, account management and plugin navigation; Vite provides the frontend development/build workflow.
- PostgreSQL and Docker Compose align with the initial persistence and deployment requirements.

## Alternatives considered

- **Python + FastAPI for the Web BFF:** technically viable, but adds a second web-side language ecosystem alongside the TypeScript frontend without a clear current requirement that outweighs that cost.
- **Plain HTML/CSS/JavaScript without React:** viable for a small static UI, but the expected interactive dashboard and reusable views make a component model preferable. React remains a UI implementation choice, not a security boundary.
- **C++ HTTP framework such as Drogon for the BFF:** not selected because browser-facing HTTP concerns belong to the separate Web component; the C++ server is primarily reached through the internal RPC contract.
- **Private HTTP/JSON:** remains a viable simpler transport alternative. gRPC is preferred for typed contracts, but M0.3 must confirm that its operational and security requirements are practical before implementation.
- **Go or Rust for the server:** viable alternatives, but C++ is selected as the initial baseline; performance alone is not the deciding factor.

## Consequences and constraints

- C++ build, dependency management, sanitizers, static analysis and reproducible CI require explicit setup in M2.
- Generated Protocol Buffer code and the `.proto` contract must be versioned and tested for compatibility.
- TypeScript types do not replace runtime validation at trust boundaries.
- React does not isolate plugin UI. Plugin UI isolation requires a separate origin or restrictive iframe sandbox and a narrow message bridge.
- The concrete PostgreSQL client library, build/dependency tooling, gRPC transport authentication and plugin runtime isolation remain open decisions for their assigned milestones.
- Do not add a second public HTTP entry point to the server. The Web BFF remains the only public application entry point by default.

## Acceptance

This ADR is accepted when the initial toolchain builds in CI, the gRPC/Protocol Buffers contract passes the M0.3 design gate, and the remaining implementation-specific choices are recorded without contradicting the architecture, IPC protocol, feature list, PRD or roadmap.
