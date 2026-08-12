# FountainMaintenanceKit — Agent Guide

Scope: reusable, portable Swift maintenance contract and typed client for Fountain-Coach services.

Invariants
- `FountainMaintenanceCore` owns typed operation identity, authorization state, idempotency, receipts, release manifests, and migration manifests.
- Secret values never enter package models, receipts, telemetry, fixtures, or logs; only opaque SecretStore references cross the client boundary.
- The package has no repository discovery, shell mutation, SSH authority, OpenAPI/backplane dependency, or host-bound identity.
- Host facilities (TLS, persistence, supervisor, filesystem, DNS, and Git) are adapters; they cannot redefine the core contract.
- Native Git is the target backend. A process adapter is transitional, explicit, and never the authority.
- Tests are deterministic and offline; MCP is optional and correctness cannot depend on it.

FCIS routing
- `PLANS.md` records intent, scope, risks, and validation.
- `.codex/skills/*/SKILL.md` contains procedures and runbooks.
- `FCIS_AUDIT.md` and `FCIS_COMPLIANCE_PLAN.md` record repository conformance.

For downstream Reframe integration, the consuming repository remains responsible for AX, FountainStore effects,
capability registry, provider consent, and live GUI acceptance.
