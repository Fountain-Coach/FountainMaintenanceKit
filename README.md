# FountainMaintenanceKit

Portable Swift contract and typed client for Fountain-Coach maintenance control planes.

This package is the shared seam between Reframe, local maintenance skills, and a hosted Book Library maintenance
service. It carries operation identity, authorization state, idempotency, sanitized terminal receipts, release
manifests, migration manifests, and opaque SecretStore references. It never carries credential values.

## Products

- `FountainMaintenanceCore` — dependency-free domain contract and admission ledger.
- `FountainMaintenanceClient` — typed URL transport boundary; authentication is supplied by a host adapter.
- `FountainMaintenanceTestKit` — deterministic offline transport and request/release fixtures.

## Support boundary

The first declared profile is macOS 14 with Swift 6.1. Linux support is a governed follow-up profile once its network,
persistence, SecretStore, supervisor, Git, build, and migration evidence exists. “Portable Swift” means the declared
profile matrix; it does not promise that every Swift runtime supplies every host facility.

## Usage

```swift
let client = try FountainMaintenanceClient(endpoint: URL(string: "https://library.example")!)
let receipt = try await client.submit(operation)
```

The caller provides an operation with an opaque `MaintenanceSecretReference`. The transport/host adapter resolves or
rejects that reference according to platform policy; the package never receives or stores a secret value.

## Governance

This repository follows FCIS. See `AGENTS.md`, `PLANS.md`, `FCIS_AUDIT.md`, and `FCIS_COMPLIANCE_PLAN.md`.
