# PostFlowX – Product Requirements Document

**Version:** 0.2  
**Status:** MVP scope defined; technical decisions pending  
**Product type:** Self-hosted social media publishing platform

## 1. Product Vision

PostFlowX is a self-hosted social media publishing platform that enables users to create, manage, schedule, and publish social media content through a web interface.

The platform combines server-side publishing, persistent scheduling, and AI-assisted text generation in a single Docker-based installation.

## 2. Target Users and Goals

PostFlowX is intended for individuals and organizations that want to manage social media publishing through their own hosted infrastructure.

The MVP aims to:

- Provide a central web interface for managing posts and social accounts.
- Support immediate and scheduled publishing.
- Automate publishing tasks through persistent background jobs.
- Assist users with AI-generated and edited text.
- Simplify installation, configuration, and maintenance through Docker Compose.

## 3. MVP Scope

### 3.1 User Access

- Secure authentication for the web interface.
- Server-side authorization for protected operations.
- Secure handling of credentials and sessions.

The initial deployment is dedicated to one customer or operator. Global SaaS multi-tenancy is out of scope.

### 3.2 Social Account Management

- Connect and manage supported social media accounts.
- Display connection status and relevant errors.
- Store access tokens and credentials securely.

**Instagram is the first supported publishing platform.** TikTok integration is planned for a later release.

Supported account types, permissions, and media formats must be verified against the applicable platform APIs before implementation.

### 3.3 Post and Media Management

Users must be able to:

- Create, edit, and delete posts.
- Save and manage drafts.
- Add captions, hashtags, and supported media.
- Select a target social account.
- Preview post content before publishing.
- Validate supported formats and platform requirements.

Media must be stored persistently and associated with the appropriate posts.

### 3.4 Publishing and Scheduling

PostFlowX supports two publishing modes:

**Manual publishing**
- Users initiate immediate publishing.
- Users control post creation and scheduling.
- Posts remain under user control.

**Automated publishing**
- Users schedule posts for future publication.
- The server processes scheduled jobs independently.
- Jobs persist across container restarts.
- Failures are recorded and handled using controlled retry rules.

Automated publishing does not imply autonomous content planning or unrestricted publication of AI-generated content.

### 3.5 Publishing Jobs

The system must maintain persistent publishing jobs with clear states, including scheduled, pending, processing, published, failed, and cancelled where applicable.

Requirements:

- Track publishing status and attempts.
- Record relevant errors and results.
- Support controlled retries.
- Prevent duplicate publications wherever technically possible.
- Handle time zones and daylight saving time.
- Recover pending work after service restarts.

Retries must account for uncertain outcomes from external APIs to avoid unintentionally publishing the same content twice.

### 3.6 AI Text Generation

The MVP includes:

- Caption generation.
- Hashtag suggestions.
- Text rewriting and shortening.
- Editing of generated suggestions before use.

AI-generated content is not automatically published unless the user explicitly configures an appropriate workflow.

AI image generation is out of scope. The AI provider must be replaceable through a defined backend interface.

## 4. Web Application

The frontend must provide:

- Authentication.
- A dashboard with relevant posts and publishing status.
- Social account management.
- Post creation and editing.
- Media uploads and selection.
- AI-assisted text editing.
- Draft management.
- Scheduling and publishing history.
- Clear error messages and job status information.

The interface should be responsive and communicate with the backend through a documented API.

## 5. Technical Architecture

The initial architecture consists of:

- **Web frontend:** User interface and client-side interactions.
- **Backend/API:** Authentication, business logic, post management, provider integrations, and job management.
- **Publishing worker:** Executes scheduled and background publishing tasks.
- **PostgreSQL:** Persistent application data and job state.
- **Optional reverse proxy:** External access and HTTPS termination where required.

The backend and publishing worker may use the same container image with different startup commands.

The backend should initially be a modular application rather than an unnecessarily distributed microservice system.

Key abstractions include:

- `PublishingProvider` for platform-specific publishing.
- `AIProvider` for AI text generation.

Initial data entities include `User`, `SocialAccount`, `MediaAsset`, `Post`, `PublishingJob`, `PublishingAttempt`, and `AuditEvent`.

## 6. Deployment and Operations

The product must be deployable through a central Docker Compose configuration.

Requirements:

- Documented environment configuration.
- Persistent database and media storage.
- Health checks and useful logs.
- Database migrations.
- Versioned container images.
- Documented installation and update procedures.
- Backup and restore procedures.
- Secure management of secrets.

The `postflowx-deploy` repository contains deployment configuration, operational tooling, and project documentation. It is not a separate application service.

## 7. Security and Reliability

The MVP must include:

- Server-side authorization.
- Secure credential and token storage.
- Input validation.
- Protection of secrets from frontend exposure and log output.
- Persistent publishing job state.
- Controlled retry and error handling.
- Tested backup and restoration procedures.

## 8. Out of Scope

The following features are excluded from the MVP:

- TikTok publishing.
- AI image generation.
- Advanced analytics and reporting.
- Plugin marketplace.
- Complex team approval workflows.
- Subscription billing and payment processing.
- Global SaaS multi-tenancy.
- Distributed multi-server deployments.
- Integrated video editing.
- Fully autonomous content campaigns.

The architecture may support future extensions without requiring these features in the initial release.

## 9. MVP Acceptance Criteria

The MVP is ready for release when:

1. A fresh installation can be deployed using the documented Docker Compose setup.
2. Application data and media survive container restarts.
3. Users can authenticate and access protected functionality.
4. An eligible Instagram account can be connected.
5. Users can create, edit, and save drafts.
6. Supported posts can be published immediately or scheduled.
7. Publishing status, attempts, and errors are traceable.
8. Scheduled jobs survive service restarts.
9. Retries are controlled and duplicate publishing is prevented wherever technically possible.
10. Users can generate and edit AI text suggestions.
11. Secrets are not exposed to the frontend or written to logs.
12. Backup restoration and essential application workflows are tested.

## 10. Development Phases

**Phase 1 – Audit and Architecture**
- Review the existing PostAPI and PostAPI-Storage implementations.
- Identify reusable publishing, token, and media-handling logic.
- Define repository boundaries and technology choices.
- Specify the initial data model and API contract.

**Phase 2 – Foundation**
- Initialize frontend and backend.
- Set up PostgreSQL, authentication, migrations, and Docker Compose.
- Establish configuration and testing conventions.

**Phase 3 – Instagram Publishing**
- Implement account integration and media handling.
- Implement post management and publishing jobs.
- Add scheduling, status tracking, retries, and failure handling.

**Phase 4 – Web UI and AI**
- Complete the post editor, drafts, scheduling, and dashboard.
- Integrate AI text generation.
- Improve error handling and usability.

**Phase 5 – Stabilization and Release**
- Run integration and security tests.
- Verify restart recovery and backup restoration.
- Finalize documentation and publish the first stable MVP release.

## 11. Open Technical Decisions

The following decisions remain open until the existing code and requirements have been reviewed:

- Backend and frontend frameworks.
- Instagram account types, permissions, and supported formats.
- AI provider and cost management.
- Job execution, locking, and retry semantics.
- Media storage and public HTTPS delivery.
- Authentication and session strategy.
- Backup security and recovery.
- Image versioning and update strategy.
- Licensing and extension model.

## 12. Next Step

The next step is to audit the existing PostAPI and PostAPI-Storage codebases before finalizing the architecture.

The audit must document reusable components, external dependencies, token handling, publishing workflows, and media delivery. The findings will inform architecture decisions, the database schema, API contracts, and implementation tasks.