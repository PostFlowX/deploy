# Product Requirements Document

**Status:** Proposed baseline  
**Product:** PostFlowX

## 1. Product summary

PostFlowX is a self-hosted social publishing platform for managing social accounts, preparing content, and publishing immediately or on a schedule. Each customer operates an installation using a central Docker Compose deployment. A web application is the primary user interface; it includes a thin Backend-for-Frontend (BFF) for browser HTTP/session concerns and forwards protected operations through the IPC Gateway to Core. Platform functionality is extended through plugins with explicit permissions and controlled access to Core services.

## 2. Problem and goals

The product should make social publishing easier to operate while keeping customer data and credentials under the customer's deployment control.

### Goals

1. Provide a reliable web UI for account management, content preparation, and publishing.
2. Support multiple application users within one installation with enforced ownership and role permissions.
3. Publish to Instagram first, including immediate and scheduled publishing.
4. Keep access tokens and other credentials encrypted at rest.
5. Provide a documented plugin interface for adding integrations and features without giving plugins unrestricted database access.
6. Deploy and upgrade the complete stack predictably using Docker Compose.
7. Recover cleanly from process restarts and interrupted jobs.
8. Add AI-assisted text generation in a later milestone, with providers behind a replaceable interface.

## 3. Non-goals for the first usable release

- Hosted multi-tenant SaaS operated by the PostFlowX project.
- TikTok publishing in the first release.
- AI image/video generation or model hosting.
- Arbitrary plugin code running inside the Core process.
- Giving plugins direct database credentials or unrestricted SQL access.
- A plugin marketplace with automatic trust guarantees.
- Kubernetes, multi-host clustering, or high availability.
- A promise that third-party social APIs will always be available or permit every requested operation.
- A custom general-purpose process supervisor where Docker's lifecycle features suffice.

## 4. Deployment and operating model

- One Compose project per customer installation.
- Separate containers for Web (frontend + thin BFF), Core, IPC Gateway, Watchdog, PostgreSQL, and each enabled plugin runtime where practical.
- Only the Web entry point is exposed to the host by default. PostgreSQL and internal services remain on private networks.
- Persistent volumes are used for database state, media files, and required operational state.
- Configuration and encryption keys are supplied as deployment secrets or protected files, never committed to source control.
- The deployment repository pins compatible image versions. Production deployments must not rely on floating `latest` tags.

## 5. Roles

### Installation administrator

Can manage installation settings, users, role assignments, plugin installation/enablement, and operational status through supported product interfaces. Does not automatically receive raw database superuser access.

### Registered user

Can manage their own social accounts, content, jobs, and authorized plugin instances. They cannot access another user's records or secrets unless an explicit permission grants that access.

### Plugin

Receives a scoped identity and a declared set of capabilities. It can only act on behalf of an authorized user and only through documented Core APIs. A plugin's requested permissions are not granted automatically.

### Deployment operator

Controls the host, Compose configuration, persistent volumes, backups, secrets, and database recovery. This role is outside normal application authorization and must be treated as highly privileged.

## 6. MVP functional scope

- Login/logout and secure session handling.
- Administrator-created users and role-based authorization.
- Core service and health reporting.
- Plugin registry and lifecycle status.
- One reference plugin to validate the plugin contract.
- Instagram account connection and token lifecycle where supported by Meta's current API and app permissions.
- Content/media metadata, publishing jobs, immediate publishing, scheduled publishing, status, retries and audit trail.
- Durable jobs that survive process restart.
- Encrypted credential storage with key material outside the database.
- Basic administration and operational diagnostics.
- Backup/restore and documented upgrade path before a production release.

## 7. Later scope

- AI text generation through a provider interface.
- More plugin integrations, including TikTok after API feasibility review.
- Improved plugin distribution, package signing, update/rollback tooling, and developer SDK.
- Optional external object storage if local persistent media storage becomes insufficient.

## 8. Product success criteria

The first usable release is successful when a fresh deployment can be started from documented instructions, an administrator can create a user, the user can connect an eligible Instagram account, publish a supported post immediately or on a schedule, inspect the final job state, and restart the stack without losing jobs or exposing another user's data.

The release is not considered production-ready until security, backup/restore, upgrade, and failure-recovery acceptance tests pass.
