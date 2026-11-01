# Linting

SwiftLint config is `.swiftlint.yml` (copied from GitKit), pinned by
`.swiftlint-version`. Existing violations are recorded in
`.swiftlint-baseline.json`; the `SwiftLint` workflow runs

```
swiftlint lint --strict --quiet --baseline .swiftlint-baseline.json
```

so only **new** violations fail CI. `Scripts/lint-regression.sh` checks the
gate itself (baseline passes, a fresh violation fails).

## Paying down the baseline

Fix violations in a file, then regenerate from the repo root:

```
swiftlint lint --quiet --write-baseline .swiftlint-baseline.json
```

Never regenerate the baseline to hide a new violation.
