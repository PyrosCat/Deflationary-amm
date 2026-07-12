# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/).

Versions follow `vMAJOR.MINOR.PATCH[-pre]`. See [docs/process/VERSION_CONTROL.md](docs/process/VERSION_CONTROL.md) for the full policy.

`v0.x` — pre-audit, pre-production. No stability guarantees on ABI or storage layout.

## [Unreleased]

### Version control reform (Session 5)

- `docs/process/VERSION_CONTROL.md`: rules rewritten around how the project
  actually operates — direct-to-main trunk for the owner (external
  contributions still branch + PR per `CONTRIBUTING.md`), branch-required
  categories (Slither / CI / problem releases) with protection toggled on
  for the duration and **Squash and Merge** everywhere, alpha tag cadence
  (owner-judged increments within a minor version, minor bump = new
  capability), one-liner tag and commit subjects with detail in the
  CHANGELOG, release runbook rewritten for the no-branch default, exact CI
  check names (`build & test`, `slither`), and new §9: documentation layout
  and session records.
- CHANGELOG repaired: `[v0.2.0-alpha.1]` section created (was missing —
  the tag's GitHub release published with an empty body) and the absent
  Session 4 content written in.
- `.github/workflows/release.yml`: guard added — the release job now fails
  with a pointed error when the tag has no matching non-empty CHANGELOG
  section, instead of publishing a blank release.
- `docs/` reorganized into `design/`, `process/`, `incidents/`,
  `frontend/`, `sessions/`; every live cross-reference updated (workflow
  comments, README, CONTRIBUTING, contract comments, deployment README;
  CHANGELOG history left as written). Stale README banner replaced with the
  actual v0.2.0-alpha.1 state.
- Session records policy adopted: `docs/sessions/WORK_SESSION_N.md`,
  committed each session, never overwritten. Sessions 3 and 4 recovered;
  the gitignored root `SESSION_HANDOFF.md` convention retired.
- `docs/incidents/2026-07-10-ci-submodules-and-slither.md`: NEW — full
  account of both Session 4 CI failures (missing submodule gitlinks;
  slither-analyzer 0.11.4 source-mapping defect). Version-pin rules
  recorded in `docs/process/STATIC-ANALYSIS.md` §7, including the pinned
  local install (`slither-analyzer==0.11.5`).

## [v0.2.0-alpha.1] — 2026-07-10

Grace-window capability complete and verified: design doc, epoch library,
GraceWindowBurnController, 98-test suite, Slither-clean CI pinned end to end.
Pre-audit; do not deploy.

### Grace-window design (Session 3) — docs, library, tests, and archive only

- `docs/DESIGN-GRACE-WINDOW.md`: resolves the Session 2 section-6a questions.
  Grace window lives in the `IBurnController` implementation as a
  parameterized schedule (`epochModulus`, `graceLengthSubunits`,
  `graceBurnBps` behind the existing 1-day timelock, plus an `anchor`
  constructor immutable); applies to the token transfer burn only. Launch
  parameter values TBD.
- `contracts/libraries/EpochLib.sol`: NEW internal library — 8-hour epochs,
  48 ten-minute subunits, anchor-parameterized, half-open grace-window
  predicates. VERIFIED against the recovered v5 `EpochUtils.sol`: 8-hour
  constant confirmed (v5's "12-hour" comment is wrong); v5's constructor
  `epochStart` adopted as the `anchor` parameter (0 = unix anchoring);
  v5's pre-anchor clamp kept on the raw getters, with pre-anchor time
  defined as never graced.
- `archive/v5/EpochUtils.sol`: NEW — the recovered v5 file, verbatim, for
  provenance (not compiled; see `archive/v5/README.md`).
- `test/EpochLib.t.sol`: NEW unit + fuzz suite (boundary-second tests,
  anchor/pre-anchor tests, v5-parity clamp test, v5-cadence reproduction,
  monotonicity and lands-in-window fuzz properties). Passing — full suite
  is 70 tests across 8 suites, 0 failures.
- `test/GraceController.CHECKLIST.md`: NEW integration test checklist for
  the future grace controller.
- `SESSION_HANDOFF.md`: NEW at repo root — Session 2 handoff with section 6a
  marked resolved and a Session 3 file table added.
- `docs/STATIC-ANALYSIS.md` + `slither.config.json`: NEW — Slither tooling
  and a first-timer's guide written for Windows/WSL2 (WSL2 + Foundry +
  Slither setup, run, triage table mapping expected findings to
  justifications, inline-suppression house style). Slither not yet run;
  config and CI exist so the first run is reproducible.
- `.github/workflows/ci.yml` + `.github/workflows/slither.yml`: NEW — the
  `build`, `test`, and `slither` CI checks named in `docs/VERSION_CONTROL.md`
  (the `.github/workflows/` directory did not previously exist).
- Slither first run + triage (35 findings, zero genuine vulnerabilities):
  inline suppressions with written justifications across AMMLiquidityPool,
  FeeManager, FeeController, DeflationaryToken; missing-inheritance fixed
  (`FlatRateBurnController is IBurnController`, `StakedTokenLP is
  IStakedTokenLP` with `IStakedTokenLP is IERC20`); `IBurnController`
  extracted to `contracts/interfaces/IBurnController.sol`. Suppression
  adjacency rule documented after five forge-lint warnings re-fired
  (directives must sit immediately above their code line).
- Slither now runs clean: 35 findings → 0. naming-convention (7, all
  idiomatic: `_param`/`__gap`/`INITIAL_SUPPLY`) excluded wholesale in
  `slither.config.json` with rationale documented in STATIC-ANALYSIS.md;
  the oracle timestamp guard uses a start/end block (multi-line comparison
  isn't covered by disable-next-line).
- Storage layout, function logic, and ABI are unchanged by the triage —
  comments, inheritance declarations, and an interface relocation only.

### GraceWindowBurnController (Session 4)

- `contracts/tokens/GraceWindowBurnController.sol`: NEW — implements
  `docs/DESIGN-GRACE-WINDOW.md` §4. `anchor` is a constructor immutable with
  no setter (clock changes = controller swap behind the token's timelock).
  Four policy values (`baseBurnBps`, `graceBurnBps`, `epochModulus`,
  `graceLengthSubunits`) packed into one storage slot and changed only
  atomically through a 1-day schedule/cancel/execute timelock — there is
  deliberately no instant `setBurnRate` (the `graceBurnBps <= baseBurnBps`
  coupling rules out independent setters). Guards: base ≤ 1000 bps,
  grace ≤ base, modulus ≥ 1, `graceLengthSubunits` > 48 rejected (not
  clamped — clamping hides owner typos). Instant `setExempt` retained for
  FlatRate parity. View helpers: `currentBurnBps()`, `graceActive()`,
  `secondsUntilNextGrace()`.
- Fail-open verified: rate lookup succeeds at half the token's 100k gas cap
  from cold storage, asserted in a test.
- `test/GraceController.t.sol`: NEW — 28 tests mapping 1:1 to
  `test/GraceController.CHECKLIST.md` (exact boundary seconds, modulus-3 and
  v5-parity configs, constructor/setter guards, timelock paths, gas-cap fit,
  swap-earmark and pool-exemption scope isolation, two-value and
  supply-monotonicity fuzz). Full suite: **98 tests, 0 failures**; the four
  pool fuzz invariants held at 2048 calls.
- Zero contract changes across two test-fix rounds — all failures were
  test-side (narrow-typed constants at a type boundary; rule recorded in
  `docs/VERSION_CONTROL.md` house conventions and the session handoff).

### CI hardening (Session 4)

- Submodule gitlinks restored: `.gitignore`'s `lib/` entry had prevented the
  three dependency gitlinks from ever reaching GitHub, so `actions/checkout`
  had nothing to initialize and CI failed with ~40 parser errors. Each dep
  was `git rm --cached`-ed and re-added via `git submodule add`; the pushed
  tree now carries three mode-160000 gitlinks and CI checkout works.
- Slither CI red resolved — root cause upstream: slither-analyzer 0.11.4
  emitted `unindexed-event-address` findings with no source mapping, so
  `filter_paths` could not match them (fixed upstream in 0.11.5, PR #2918).
  Workflow now pins **slither-action v0.4.2 + slither-analyzer 0.11.5**
  together (0.11.5 requires Python ≥ 3.10, which the v0.4.1 image lacked),
  plus explicit `solc-version: "0.8.24"` and `slither-config`.
  Result: `fail-on: all`, 0 findings, no detectors suppressed.
- Verified during triage: every project-owned event already indexes its
  address parameters; the detector stays active as a guard.
- House rule recorded: local and CI Slither track the same pinned version —
  the pin is the authority, not either environment.

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
