# Session handoff — end of Session 3

Written at the close of Session 3 for whoever picks this up in Session 4 (you,
later, or a fresh assistant context). Supersedes the Session 2 handoff
entirely. Read this first; it is the fastest path back to full context.

---

## 1. What this project is

**Deflationary-amm** — a modular, upgradeable (UUPS) constant-product AMM built
to safely host fee-on-transfer deflationary tokens, plus a fixed-supply
deflationary ERC-20 with a hard-capped, pluggable burn policy. The end goal it
serves: a token/AMM layer for online games the owner (GitHub: **PyrosCat**)
designs, where in-game sinks drive deflation. That gaming layer is future work;
this repo is the financial substrate.

Repo target: `github.com/PyrosCat/Deflationary-amm`. License MIT.
Current tag: **v0.1.0-alpha.1**. Next tag: **v0.2.0-alpha.1** (see section 6).

---

## 2. Honest status at end of Session 3

This is the most important section. Do not let it drift ahead of reality.

| Gate | Status |
|---|---|
| Compiles (`forge build`, via-IR) | **GREEN** — solc 0.8.24, via-IR, warning-free (the 5 forge-lint warnings from the mid-session suppression edits were fixed) |
| Lint (`forge build` warnings) | **GREEN** — all suppressed with justified inline comments; adjacency verified (directives sit immediately above their code line) |
| Full unit + integration suite | **GREEN** — 70 tests across 8 suites, 0 failures (55 prior + the Session 3 EpochLib suite) |
| Fuzz invariants | **GREEN** — reserve identity, K-never-decreases, min-liquidity-locked, earmarks-backed; EpochLib fuzz props (subunit range, epoch monotonic, lands-in-window, pre-anchor-never-graced) |
| Slither static analysis | **GREEN / CLEAN** — `slither .` reports **0 results** (down from 35 first-run); all triaged, suppressed inline, or (naming-convention) excluded in config with documented rationale |
| CI workflows exist | **YES** — `.github/workflows/ci.yml` (build+test) and `slither.yml`; **not yet run on GitHub** (repo not pushed with these) |
| Slither run in CI | **NOT YET** — local WSL2 run is clean; first CI run pending push |
| Audit | **NOT DONE** — required before any mainnet consideration |
| Deployed anywhere | **NO** |

---

## 3. What Session 3 did (the arc)

### 3a. EpochUtils / grace-window architecture — RESOLVED
The recovered v5 `EpochUtils.sol` was re-provided and **verified**. Findings
(full detail in `docs/DESIGN-GRACE-WINDOW.md` section 2): v5 was NOT
unix-anchored (it took a constructor `epochStart`), so the v6 library takes an
`anchor` parameter (0 = unix anchoring); the 8-hour epoch / 10-min subunit
constants were confirmed (v5's "12-hour" comment is wrong); v5's pre-anchor
clamp is preserved, with pre-anchor time defined as never-graced.

Decision: the grace window lives in the `IBurnController` implementation as a
**parameterized schedule** — `epochModulus`, `graceLengthSubunits`,
`graceBurnBps` (all owner-settable behind the 1-day timelock) plus an `anchor`
constructor immutable. Applies to the **token transfer burn only**; the AMM
swap earmark stays independent. Reproducing v5 exactly is a parameter choice
(`3 / 48 / 0`), not code. Launch parameter values are still **TBD**.

Shipped: `contracts/libraries/EpochLib.sol` (internal, pure, anchor-param),
`test/EpochLib.t.sol` (unit + fuzz, **passing**), `archive/v5/EpochUtils.sol`
(verbatim, provenance, not compiled), `docs/DESIGN-GRACE-WINDOW.md`,
`test/GraceController.CHECKLIST.md`.

### 3b. Slither — first run, triaged to clean
Installed and run in WSL2 (Windows host; see `docs/STATIC-ANALYSIS.md` for the
WSL2 setup). First run: 35 findings. Triage outcome — **zero genuine
vulnerabilities**:
- **Reentrancy** findings are real patterns but not exploitable:
  deposit/withdraw/swap/sync all carry `nonReentrant` (verified in source), so
  the post-transfer `_syncReserves()` writes and balance-delta reads are
  guarded. Suppressed with rationale.
- **divide-before-multiply** (6), **timestamp** (4), **incorrect-equality**
  (7), **low-level-call** (1): all intended patterns (UQ112 oracle, bps math,
  1-day timelocks, zero-guards, fail-open burn probe). Suppressed inline.
- **missing-inheritance** (2): FIXED in code — `FlatRateBurnController is
  IBurnController`, `StakedTokenLP is IStakedTokenLP` (interface now `is
  IERC20`), with `override` keywords.
- **naming-convention** (7): excluded wholesale in config (all idiomatic:
  `_param` names, `__gap`, `INITIAL_SUPPLY`), rationale in the doc.

Second run: **0 results.**

### 3c. IBurnController extracted
Moved from inside `DeflationaryToken.sol` to
`contracts/interfaces/IBurnController.sol`. Controller implementations
(FlatRateBurnController today, the grace controller next) now import a small
interface instead of the whole token contract. No behaviour change.

### 3d. Tooling and CI added
`slither.config.json` (remappings, path filters, dependency + naming-convention
exclusion), `docs/STATIC-ANALYSIS.md` (WSL2-first Slither guide),
`.github/workflows/ci.yml` and `slither.yml` (the build/test/slither checks
`docs/VERSION_CONTROL.md` already referenced; `.github/workflows/` did not
previously exist). `release.yml` was already present and is untouched.

### 3e. Hard-won lesson: suppression adjacency
`forge-lint: disable-next-line` and `slither-disable-next-line` apply strictly
to the *immediately following* line. Inserting a comment between the directive
and its code silently breaks the suppression — this re-fired 5 lint warnings
mid-session. Rule now documented and applied tree-wide: justification prose
ABOVE, machine directive IMMEDIATELY above the code; use
`slither-disable-start/end` blocks for multi-line comparisons and
function-level findings. (The oracle guard is a multi-line comparison and
needed the start/end form.)

---

## 4. Architecture and key design constraints (do not regress)

- **AMM compatibility is a hard constraint on token design.** Sender-pays
  transfer tax semantics are load-bearing for AMM reserve accounting. Cannot be
  relaxed without breaking pool math.
- **Storage discipline is sacred.** All state lives in `LiquidityPoolStorage`;
  modules hold no state variables. New storage appended to `__gap` only, never
  reordered. Violating this breaks UUPS upgrade safety silently.
- **Fail-open burn controller.** Gas-capped `try/catch` in the token prevents a
  misbehaving controller from bricking transfers. The grace controller must
  keep its rate lookup cheap and revert-free to stay inside that cap.
- **Deposit burn rate defaults to zero** (recommended). Current default in
  `initialize` is 0.10% — schedule an update to 0 via the timelock after
  deployment.
- **Token contracts are immutable by design.** No upgrade path. The grace
  window therefore lives in the swappable controller, never the token.
- **Deployment order is encoded in `script/Deploy.s.sol`:** token (tax off) →
  controller → LP token → pool proxy → `setMinter(proxy)` → exempt pool →
  schedule + activate controller behind 1-day timelock. The pool is
  tax-exempt: swaps never pay the transfer burn (relevant to grace-window MEV).
- **Honesty is a deliverable.** All docs state plainly that the code is
  unaudited and pre-mainnet. Do not let docs drift ahead of reality.

---

## 5. The v5 bugs that v6 fixes (institutional memory — do not regress)

Each has a passing regression test in `test/Regression.t.sol`:

1. **Swap mispricing** — v5 read live balances (already holding the swap input)
   then added the input again, ~doubling price impact. Fixed by pricing off
   stored pre-trade reserves; `MathUtils.getAmountOut` takes reserves as params.
2. **First-depositor inflation attack** — no minimum-liquidity lock. Fixed by
   burning `MINIMUM_LIQUIDITY` (1000 wei LP) to the dead address on first
   deposit.
3. **Fee-on-transfer deposit** — v5 trusted stated amounts. Fixed with
   balance-delta measurement (`_pullMeasured`) on both deposit and swap.

---

## 6. Session 4 — start here (ordered)

### 6a. FIRST: tag `v0.2.0-alpha.1`

Session 3's work is a coherent, verified increment sitting in the CHANGELOG
`[Unreleased]` section: the grace-window design + EpochLib (new capability),
the Slither triage + tooling, and the IBurnController extraction. Per semver
and `docs/VERSION_CONTROL.md`, new backward-compatible functionality is a
**minor** bump — hence `v0.2.0-alpha.1`, not a patch. The build is green
(70 tests, clean Slither), so this tags a verified state.

Runbook (from `docs/VERSION_CONTROL.md`):
1. Confirm green locally: `forge build` (warning-free), `forge test`
   (70 passing), `slither .` (0 results).
2. Push to `github.com/PyrosCat/Deflationary-amm` and confirm the three CI
   checks (build, test, slither) pass on GitHub Actions — **this is their
   first real run**; watch the via-IR build time and the Slither baseline.
   Fix any CI-only failures before tagging.
3. Move the CHANGELOG `[Unreleased]` block down under a dated
   `## [0.2.0-alpha.1] — <date>` header.
4. Tag `v0.2.0-alpha.1`; `release.yml` (already present) fires on the
   `v*.*.*-*` tag pattern and cuts the GitHub release.

Do NOT tag before CI is green on GitHub — a tag that fires the release
workflow on a red build is the thing the honesty rule exists to prevent.

**Verify before tagging:** the missing-inheritance fixes + IBurnController
extraction are comment/inheritance/interface-relocation only (no logic), and
the last full local re-verify confirmed `forge build` warning-free and
`slither .` at 0 results. Re-run `forge test` once more to confirm 70 green
still holds after those inheritance edits before tagging. Verify, don't assume.

### 6b. Then: build the grace controller

The design is fully specified (`docs/DESIGN-GRACE-WINDOW.md`); the math library
(`EpochLib`) is written, tested, and verified against v5. Remaining work is the
consumer:
- Implement `GraceWindowBurnController is IBurnController` (imports the extracted
  interface). It reads `EpochLib.graceActive(...)` and returns `graceBurnBps`
  inside the window, `baseBurnBps` outside.
- `anchor` is a **constructor immutable**; `epochModulus` /
  `graceLengthSubunits` / `graceBurnBps` are owner-settable behind the 1-day
  timelock with the setter guards enumerated in the design doc (modulus >= 1,
  graceBurnBps <= base, etc.).
- View helpers for the frontend: `currentBurnBps()`, `graceActive()`,
  `secondsUntilNextGrace()`.
- Write the integration tests in `test/GraceController.CHECKLIST.md` alongside
  the controller (boundary seconds, timelocked setters, fail-open gas fit,
  scope isolation from the swap earmark, two-value fuzz).
- Decide launch parameters (`epochModulus` / `graceLengthSubunits` /
  `graceBurnBps` / `anchor`) — still TBD; design doc has the tradeoff tables
  and recommendations (`1 / 6 / TBD / 0`).
- Re-run `slither .` on the new controller; expect a `timestamp` finding on the
  epoch consumer — justify inline per the house style (10-min granularity).

### 6c. Then: Phase 3 parameter decisions
- Schedule `depositBurnBps` → 0 via the timelock (1-day delay).
- Confirm router/zap scope for the frontend.

### 6d. Then: Phase 4 — multisig + audit
Contract surface frozen, full suite verified, fuzz invariants held, Slither
clean. That is a reasonable audit-readiness posture. Do NOT deploy to mainnet
before the audit completes.

---

## 7. Document map

- `SESSION_HANDOFF.md` — this file (repo root)
- `README.md` — repo landing page
- `docs/ARCHITECTURE.md` — full architecture, economics, proxy design, roadmap
- `docs/DESIGN-GRACE-WINDOW.md` — grace-window design record (authoritative)
- `docs/STATIC-ANALYSIS.md` — Slither guide (WSL2 setup, run, triage,
  suppression house style incl. the adjacency rule)
- `docs/TESTING.md` — Foundry guide for a Hardhat user
- `docs/HANDOFF-FRONTEND.md` — frontend integration + design handoff (UX rules
  U1–U6 are contract-derived, not optional)
- `docs/VERSION_CONTROL.md` — branching, semver, release runbook
- `SECURITY.md`, `CONTRIBUTING.md`, `CHANGELOG.md` — policy, workflow, history

---

## 8. Longer horizon (beyond the current roadmap)

- **Gaming layer** — dual-currency economy, one-way premium→soft bridge, entry-
  fee rake burns as the primary deflation engine.
- **Solana port** — Anchor implementation, reusing the invariant suite as spec.
  The economic core ports; the OZ/UUPS/permit machinery is replaced by Anchor
  idioms.
- **QFCalc module** — the owner's quant-finance calculator could gain a module
  modelling supply decay S(t) under burn fraction and velocity, plus the
  sources-vs-sinks ratio that determines whether the game economy is net-
  deflationary.

---

## 9. Files changed in Session 3

Zero changes to contract *logic*, storage layout, or ABI — comments,
inheritance declarations, an interface relocation, plus new docs/tests/config.

| File | Change |
|---|---|
| `docs/DESIGN-GRACE-WINDOW.md` | NEW — grace-window design record (authoritative; v5 provenance verified) |
| `docs/STATIC-ANALYSIS.md` | NEW — Slither guide for Windows/WSL2, first-time user; adjacency + config-exclusion rules |
| `contracts/libraries/EpochLib.sol` | NEW — internal library, anchor-parameterized epoch math, verified against v5 |
| `contracts/interfaces/IBurnController.sol` | NEW — interface extracted from DeflationaryToken.sol |
| `archive/v5/EpochUtils.sol` + `README.md` | NEW — recovered v5 file, verbatim, provenance only (not compiled) |
| `test/EpochLib.t.sol` | NEW — unit + fuzz suite (passing; part of the 70) |
| `test/GraceController.CHECKLIST.md` | NEW — integration test checklist for the future controller |
| `slither.config.json` | NEW — remappings, path filters, dependency + naming-convention exclusion |
| `.github/workflows/ci.yml` + `slither.yml` | NEW — build/test + static-analysis CI |
| `contracts/AMMLiquidityPool.sol` | Slither suppressions w/ justifications (reentrancy/equality/div-mul/timestamp); oracle guard uses start/end; zero logic change |
| `contracts/modules/FeeManager.sol` | Slither suppressions (events/low-level/equality); zero logic change |
| `contracts/modules/FeeController.sol` | Suppression adjacency fix on timelock guards; zero logic change |
| `contracts/tokens/DeflationaryToken.sol` | Imports extracted IBurnController; suppression adjacency fix; zero logic change |
| `contracts/tokens/FlatRateBurnController.sol` | `is IBurnController` + `override`; imports extracted interface |
| `contracts/tokens/StakedTokenLP.sol` | `is IStakedTokenLP` + `override` on mint/burn |
| `contracts/interfaces/IStakedTokenLP.sol` | Now `is IERC20`; redundant totalSupply/balanceOf declarations removed |
| `CHANGELOG.md` | `[Unreleased]` entries for all of the above |
