---
name: repo-ops
description: Validate FountainMaintenanceKit locally and offline.
---

# Repository validation

Run from the repository root:

```sh
swift test
git diff --check
```

Do not add credentials, contact a remote maintenance service, or substitute live deployment for package validation.
