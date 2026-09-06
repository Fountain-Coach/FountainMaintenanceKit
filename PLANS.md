## Current bounded change — portable approval contract promotion (2026-09-06)

Capability: promote the server-owned approval challenge, trusted-device signature verification, redacted broker
receipt, and HTTPS/loopback client transport into the published `FountainMaintenanceKit` consumed by Linux hosts.

Chapters read: Reframe 07, 08, 63, and 131. The published package is the reusable contract; host listeners,
SecretStore custody, browser/mobile UI, DNS, TLS provisioning, Reframe, and deployment remain outside this slice.

Proof gate: `swift test` passes for the package; challenge projections contain no private request fields; invalid,
expired, replayed, and mismatched approvals fail or become terminal according to the typed broker state; client
routes only to HTTPS or loopback HTTP and sends only the signed submission envelope; `git diff --check` passes.

Implementation result: add the approval contract to `FountainMaintenanceCore`, the native URLSession transport to
`FountainMaintenanceClient`, and deterministic fixtures/tests. No hosted endpoint or DNS claim is made by this
phase.

Deferred: update Book Library to a released package revision, expose the native `/approve/<challengeID>` route,
configure the real SecretStore/host adapter, and perform the separate remote HTTPS/DNS acceptance.

Title: FountainMaintenanceKit v0.1 — portable maintenance contract

Goal: Publish the reusable FCIS-governed Swift core and typed client so Reframe and maintenance services consume one
versioned contract across declared Swift platform profiles.

Scope: Core operation models, SecretStore references, idempotency ledger, sanitized receipts, release/migration
manifests, typed transport client, offline fixtures/tests, documentation, FCIS evidence, and first tagged release.

Non-goals: Native Git implementation, real SecretStore provider, hosted server deployment, Reframe UI, FountainStore,
OpenAPI, SSH, or live remote mutation.

Constraints: Swift Package Manager; no third-party runtime dependencies; deterministic offline tests; no secrets;
macOS 14 is the first supported profile.

Risks: A local copy could drift from the published kit; downstream must resolve a tagged repository revision and run
dependency coherence before acceptance.

Plan:
- Step 1 (status: completed) - Publish core/client/test-kit modules with FCIS repository surfaces.
- Step 2 (status: completed) - Run offline package tests and inspect the generated release boundary.
- Step 3 (status: completed) - Tag and push the first release, then switch Reframe to the remote package.
- Step 4 (status: completed) - Correct the package profile for Linux server consumption and release the patch version.
- Step 5 (status: completed) - Add the Chapter 117 typed deterministic recovery projection boundary and offline tests.
- Step 6 (status: in_progress) - Release the recovery projection as the next semver revision and wire Reframe to the exact upstream revision.

Validation:
- `swift test`
- `git diff --check`
- downstream `swift package resolve` and dependency-coherence check
- downstream focused `FountainGitServiceClientTests`
- recovery projection determinism, asset disposition, and receipt identity tests
