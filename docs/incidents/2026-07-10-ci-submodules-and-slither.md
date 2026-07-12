# Incident: first CI runs red — missing submodule gitlinks, then Slither false findings

**Date resolved:** 2026-07-10 (Session 4)
**Status:** resolved; both root causes fixed and pinned
**Commits:** `8e5c8cd` (gitlinks), `bcfcbf2` (Slither pins)
**Outcome:** `v0.2.0-alpha.1` cut from the first fully green CI state

---

## Failure 1 — `lib/` submodules never reached GitHub

**Symptom:** first real CI run produced ~40 solc parser errors, all
downstream of `lib/` being empty on the runner.

**Root cause:** `.gitignore` contained `lib/`, which prevented the submodule
**gitlinks** (the mode-`160000` pointer entries) from ever being committed
and pushed. `.gitmodules` declared three submodules, but `actions/checkout`
with `submodules: recursive` had no gitlinks to follow. Invisible locally:
gitignore does not affect already-present working trees, and the local
clones existed.

**Fix:** `git rm --cached` each dependency (required — a plain `git add`
registers *embedded repositories*, not gitlinks), then re-add via
`git submodule add <url> lib/<name>`. Verified `git ls-files -s lib` shows
three mode-`160000` entries before pushing.

**Policy note (Session 5):** `lib/` deliberately **stays** in `.gitignore`.
The gitlinks are already tracked, so the ignore line does not affect them,
and it keeps build artifacts under `lib/` unstageable. Consequence to
remember: a future `git submodule add` under `lib/` needs `-f`.

**False lead, recorded so it isn't re-chased:** the CI log printed
`Dependency 'lib\openzeppelin-contracts'` with a backslash, suggesting
committed Windows path separators. It was a forge display artifact;
`cat -A` on the pushed `.gitmodules` was clean.

---

## Failure 2 — Slither red on findings local runs could not reproduce

**Symptom:** CI reported 3 `unindexed-event-address` findings, all in
OpenZeppelin files under `lib/`, despite `slither.config.json` filtering
`lib|test|script|archive`. Local WSL2 runs: 0 findings.

**Root cause (upstream):** slither-analyzer **0.11.4** shipped the detector
emitting findings **with no source mapping**, so `filter_paths` and
`exclude_dependencies` — which match on source-mapped elements — had
nothing to match. Fixed upstream in **0.11.5** (PR #2918). The local
environment happened to be on 0.11.5 already; CI (slither-action v0.4.1)
was on 0.11.4. The config was never at fault.

**Complication:** 0.11.5 requires Python ≥ 3.10, which the v0.4.1 action
image lacks. Fix therefore bumped both together: **slither-action v0.4.2 +
slither-analyzer 0.11.5**, plus explicit `solc-version: "0.8.24"` (the
action had been guessing 0.8.20) and explicit `slither-config`.

**Outcome:** `fail-on: all`, 0 findings, no detectors suppressed.

**False lead, recorded:** the divergence was first theorized as a
version/detector gap. The evidence inverted it (local 0.11.5 = newer, 100
detectors, 0 findings; CI 0.11.4 = older, 99 detectors, 3 findings), and
the mechanism was ultimately the source-mapping defect, not detector
coverage.

**Verified during triage:** every project-owned event already indexes its
address parameters (all of `contracts/` audited by grep plus manual check
of multi-line events). `unindexed-event-address` stays active as a guard.

---

## Rules earned (recorded in `docs/process/STATIC-ANALYSIS.md` §7)

1. Local and CI Slither are pinned to the **same** version; neither
   environment is authoritative — the pin is.
2. The analyzer pin must be installable in the Python shipped by the pinned
   action image; bumping across a `Requires-Python` boundary means bumping
   the action first. Record the coupling in `dependabot.yml` if dependabot
   is ever enabled for `github-actions`.
3. Never tag before CI is green **on GitHub**. Both failures were
   packaging/config defects that local runs are structurally incapable of
   catching; the gate did its job on its first outing.
