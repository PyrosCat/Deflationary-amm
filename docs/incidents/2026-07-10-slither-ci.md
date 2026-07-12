# Slither CI Resolution Report

**Status:** Resolved

---

## Symptom

Local `slither .` returned 0 findings across 51 contracts (100 detectors).
The GitHub Actions run on identical code returned 3 findings (99 detectors),
all `unindexed-event-address` hits on OpenZeppelin library files under `lib/`:

- `IERC1967.AdminChanged`
- `PausableUpgradeable.Paused`
- `PausableUpgradeable.Unpaused`

With `fail-on: all`, this failed the check.

---

## Root cause

Two compounding issues.

**Version drift.** CI pinned `slither-version: "0.11.4"`; local was running
0.11.5. The one-detector delta (99 vs 100 after `naming-convention` exclusion)
confirmed this.

**Detector defect in 0.11.4.** That release introduced
`unindexed-event-address`, but the detector emitted findings with no source
mapping. Since `filter_paths` and `exclude_dependencies` match against a
result's source-mapped elements, the OZ findings had nothing to match on and
passed straight through the config. `slither.config.json` was never at fault.
Upstream fixed this in 0.11.5 (PR #2918, "add source mapping information to
detection").

---

## Complication

Bumping `slither-version` to `0.11.5` alone failed:

```
ERROR: Ignored the following versions that require a different python version: 0.11.5 Requires-Python >=3.10
ERROR: No matching distribution found for slither-analyzer==0.11.5
```

0.11.5 raised the minimum to Python 3.10. The `slither-action@v0.4.1`
container ships an older Python, so pip refused the install inside the image.

---

## Fix applied

Bumped both the action and the analyzer in `.github/workflows/slither.yml`:

```yaml
      - name: Run Slither
        uses: crytic/slither-action@v0.4.2
        with:
          slither-config: slither.config.json
          solc-version: "0.8.24"
          slither-version: "0.11.5"
          fail-on: all
```

The v0.4.2 image carries a Python new enough for 0.11.5.

---

## Verification

CI now reports 0 findings, matching local. `fail-on: all` retained; no
detectors suppressed.

---

## Notes for `docs/process/STATIC-ANALYSIS.md`

- The pinned CI version and the local install must be bumped together. Add
  `slither --version` to the local setup instructions so the drift is visible
  before it reaches CI.
- The action version and the analyzer version are separate pins with a Python
  compatibility coupling between them. Bumping the analyzer may require bumping
  the action.
- No detector was excluded to reach the clean baseline. `unindexed-event-address`
  is active and would still flag unindexed address params in `src/`, which is
  the intended behavior.
- Consider `.github/dependabot.yml` with `package-ecosystem: "github-actions"`
  to get notified of future action releases rather than discovering the gap
  through a failing build.
