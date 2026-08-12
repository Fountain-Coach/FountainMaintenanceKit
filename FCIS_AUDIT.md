# FCIS_AUDIT.md

Status: COMPLIANT — initial release surface

| Requirement | Status | Evidence |
| --- | --- | --- |
| Declarative agent guide | PASS | `AGENTS.md` contains scope and invariants only |
| Intent protocol | PASS | `PLANS.md` contains goal, scope, risks, plan, validation |
| Procedure separation | PASS | `.codex/skills/repo-ops/SKILL.md` contains the test runbook |
| Offline correctness | PASS | `swift test` runs without service credentials or MCP |
| Secret boundary | PASS | Core types model opaque references only; tests assert redaction |
| Host portability | PASS | Core identities use aliases, not IPs, paths, or leases |
