# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/).

Versions follow `vMAJOR.MINOR.PATCH[-pre]`. See [docs/process/VERSION_CONTROL.md](docs/process/VERSION_CONTROL.md) for the full policy.

`v0.x` — pre-audit, pre-production. No stability guarantees on ABI or storage layout.

## [Unreleased]
### Version control reform

- `docs/process/VERSION_CONTROL.md`: rules rewritten — direct-to-main trunk,
  branch-required categories (Slither / CI / problem releases), alpha tag
  cadence, one-liner subjects, release runbook, exact CI check names.
- `docs/` reorganized into `design/`, `process/`, `incidents/`, `frontend/`,
  `sessions/`; all cross-references updated.
- `docs/sessions/WORK_SESSION_3.md`, `WORK_SESSION_4.md`: NEW — work session
  records; session records policy adopted (`WORK_SESSION_N.md`, never
  overwritten).
- `docs/incidents/2026-07-10-slither-ci.md`: NEW — Slither CI resolution
  report (slither-analyzer 0.11.4 source-mapping defect; version-pin
  coupling).
- `.github/workflows/release.yml`: guard added — release job fails when the
  tag has no matching non-empty CHANGELOG section.

### Code style

- `forge fmt` applied across `contracts/`, `test/`, and `script/` (20 files);
  formatting-only, no logic change. Repo now passes `forge fmt --check`.

## [v0.2.0-alpha.1] — 2026-07-10

Grace-window capability complete and verified: design doc, epoch library,
GraceWindowBurnController, 98-test suite, Slither-clean CI pinned end to end.
Pre-audit; do not deploy.

### Grace-window design

- `docs/design/DESIGN-GRACE-WINDOW.md`: NEW — grace window lives in the
  `IBurnController` implementation as a parameterized schedule
  (`epochModulus`, `graceLengthSubunits`, `graceBurnBps` behind the existing
  1-day timelock, plus an `anchor` constructor immutable); applies to the
  token transfer burn only. Launch parameter values TBD.
- `contracts/libraries/EpochLib.sol`: NEW internal library — 8-hour epochs,
  48 ten-minute subunits, anchor-parameterized, half-open grace-window
  predicates. 8-hour constant confirmed; pre-anchor time is defined as never
  graced.
- `archive/v5/EpochUtils.sol`: NEW — recovered v5 file, verbatim, for
  provenance (not compiled; see `archive/v5/README.md`).
- `test/EpochLib.t.sol`: NEW unit + fuzz suite (boundary-second tests,
  anchor/pre-anchor, v5-parity clamp, monotonicity and lands-in-window fuzz).
  70 tests across 8 suites, 0 failures.
- `test/GraceController.CHECKLIST.md`: NEW integration test checklist for
  the grace controller.
- `docs/process/STATIC-ANALYSIS.md` + `slither.config.json`: NEW — Slither
  tooling guide (WSL2 setup, run, triage table, inline-suppression house
  style).
- `.github/workflows/ci.yml` + `.github/workflows/slither.yml`: NEW — CI
  checks (`build & test`, `slither`).
- Slither first run + triage: 35 findings, zero genuine vulnerabilities.
  Inline suppressions with written justifications across AMMLiquidityPool,
  FeeManager, FeeController, DeflationaryToken; missing-inheritance fixed
  (`FlatRateBurnController is IBurnController`, `StakedTokenLP is
  IStakedTokenLP`); `IBurnController` extracted to
  `contracts/interfaces/IBurnController.sol`. naming-convention (7, all
  idiomatic) excluded wholesale in `slither.config.json`. Slither clean:
  35 findings → 0. Storage layout, function logic, and ABI unchanged.

### GraceWindowBurnController

- `contracts/tokens/GraceWindowBurnController.sol`: NEW — implements
  `docs/design/DESIGN-GRACE-WINDOW.md` §4. `anchor` is a constructor
  immutable with no setter. Four policy values (`baseBurnBps`,
  `graceBurnBps`, `epochModulus`, `graceLengthSubunits`) packed into one
  storage slot, changed only atomically through a 1-day timelock; no instant
  `setBurnRate`. Guards: base ≤ 1000 bps, grace ≤ base, modulus ≥ 1,
  `graceLengthSubunits` > 48 rejected. Instant `setExempt` retained.
  View helpers: `currentBurnBps()`, `graceActive()`,
  `secondsUntilNextGrace()`. Fail-open verified at half the 100k gas cap.
- `test/GraceController.t.sol`: NEW — 28 tests (boundary seconds, modulus
  configs, constructor/setter guards, timelock paths, gas-cap fit, scope
  isolation, fuzz). Full suite: **98 tests, 0 failures**; four pool fuzz
  invariants held at 2048 calls. Zero contract changes across two test-fix
  rounds.

### CI hardening

- Submodule gitlinks restored: `actions/checkout` had nothing to follow
  (three mode-160000 entries now present); CI checkout works.
- Slither CI resolved: slither-analyzer 0.11.4 emitted findings with no
  source mapping (fixed upstream in 0.11.5, PR #2918). Pinned
  **slither-action v0.4.2 + slither-analyzer 0.11.5**; explicit
  `solc-version: "0.8.24"` and `slither-config` added. Result: `fail-on:
  all`, 0 findings, no detectors suppressed.

---

## [v0.1.0-alpha.1] — 2026-07-05

First tagged commit. Contracts written and reviewed; not compiled, not executed,
not audited. Phase 0 of the roadmap complete (contract surface frozen).
Do not deploy to mainnet.

### Phase 0 — contract surface frozen
- EIP-2612 permit on `DeflationaryToken` and `StakedTokenLP`.
- Two-step ownership (`Ownable2Step`) on the pool and `DeflationaryToken`.
- All `require` strings converted to custom errors; data-carrying where useful
  (`SlippageExceeded(actual, minimum)`, `TimelockActive(executeAfter)`, `FeeAboveCap(requested, cap)`).
- TWAP oracle accumulators (Q112, Uniswap V2 semantics) in `_syncReserves`;
  storage gap reduced 40 → 37 to keep the layout footprint constant.
- `pendingFees` / `pendingSplit` made `public` for frontend readability.

### Added
- Full Foundry test suite (~1,070 lines across 7 files): unit, fuzz, invariant,
  proxy, and 3 regression tests pinning v5 bugs.
- CI: build + test + coverage + storage-layout diff + Slither + automated
  release workflow (`.github/workflows/`).
- Deployment scripts (`script/Deploy.s.sol`, `ActivateController`).
- Deployment records directory (`deployments/`) — empty pending first testnet run.
- Version control strategy: branching model, commit conventions, semver policy,
  release runbook (`docs/VERSION_CONTROL.md`).
- Repository scaffolding: `README.md`, `CONTRIBUTING.md`, `SECURITY.md`,
  `CHANGELOG.md`, `LICENSE`, `.gitignore`, `.env.example`, `INIT_REPO.sh`.
- Documentation: `docs/ARCHITECTURE.md`, `docs/TESTING.md`,
  `docs/HANDOFF-FRONTEND.md`, `docs/VERSION_CONTROL.md`.

### v6 rewrite (preceding this tag, included for provenance)
- Ground-up modular rewrite replacing the v5 monolith.
- Fixed swap pricing: uses stored pre-trade reserves (v5 double-counted input).
- Added `MINIMUM_LIQUIDITY` lock (first-depositor inflation attack).
- Balance-delta accounting on deposit and swap (fee-on-transfer safe).
- Three-way swap fee split (LP yield / burn / protocol); LPs previously earned nothing.
- Removed commit-reveal subsystem (bound nothing; not atomic; no real MEV protection).
- Production tokens: hard-capped fail-open burn controller, true burns,
  `ERC20Burnable`, one-shot LP minter.

### Not yet done (next milestones)
- `forge build` (milestone zero — see `docs/TESTING.md` section 11 for triage)
- `forge test` green
- `slither` triaged
- Testnet deployment
- Professional audit
- Ownership to multisig

[v0.2.0-alpha.1]: https://github.com/PyrosCat/Deflationary-amm/releases/tag/v0.2.0-alpha.1
[v0.1.0-alpha.1]: https://github.com/PyrosCat/Deflationary-amm/releases/tag/v0.1.0-alpha.1
