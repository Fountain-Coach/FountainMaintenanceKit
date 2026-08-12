# FCIS_COMPLIANCE_PLAN.md

## Goal

Keep the package compliant with FCIS RFC 0001 and Chapter 63 by separating invariants (`AGENTS.md`), intent and
validation (`PLANS.md`), and procedures (`.codex/skills`).

## Checklist

- AGENTS is declarative and contains no runbook commands.
- PLANS names scope, non-goals, risks, phases, and validation.
- Skills contain procedures when a reusable runbook is needed.
- No MCP, credential, host path, or remote service is required for package correctness.
- Package tests are deterministic and offline.
