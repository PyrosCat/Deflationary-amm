# Architecture — Deflationary AMM

A modular, upgradeable (UUPS) constant-product AMM with a three-way swap fee split (LP yield / burn / protocol), built to safely host fee-on-transfer deflationary tokens. Includes a production deflationary ERC20 with a hard-capped, pluggable burn policy, a one-shot-minter LP token, and a reference burn controller.

**Status: pre-compilation draft. No automated tests exist yet. Not audited. Do not deploy to mainnet.**

The code in this repo was produced by fixing a reviewed v5 codebase (compile errors, a swap mispricing bug, a first-depositor attack vector, and several economic gaps). It has been carefully reviewed by hand but has not yet been compiled or executed. Treat `forge build` passing as milestone zero.

---

## 1. File structure

```
contracts/
├── AMMLiquidityPool.sol            Main pool: UUPS orchestrator, deposit/withdraw/swap
├── storage/
│   └── LiquidityPoolStorage.sol    ALL persistent state + upgrade gap (single source of truth)
├── modules/
│   ├── FeeController.sol           Timelocked fee governance (schedule/execute/cancel, hard caps)
│   └── FeeManager.sol              Protocol fee withdrawal + permissionless burn crank
├── libraries/
│   ├── MathUtils.sol               Pure math: sqrt, min, constant-product getAmountOut
│   └── ERC20Utils.sol              Safe transfer helpers with code-existence checks
├── interfaces/
│   └── IStakedTokenLP.sol          LP token interface consumed by the pool
└── tokens/
    ├── DeflationaryToken.sol       Fixed-supply ERC20 with capped, fail-open transfer burn
    ├── StakedTokenLP.sol           LP share token, minter bindable exactly once
    └── FlatRateBurnController.sol  Reference IBurnController: flat rate + exemption list
```

## 2. File purposes and what was done to each

| File | Purpose | Key changes vs v5 |
|---|---|---|
| `AMMLiquidityPool.sol` | User-facing pool logic. Thin orchestrator inheriting all modules. | Rewritten. Pricing now uses stored pre-trade reserves (fixes the v5 double-count bug where live balances already contained the swap input). Inbound funds measured by balance delta on both `deposit` and `swap` via `_pullMeasured` (fee-on-transfer safe). `MINIMUM_LIQUIDITY` (1000 wei LP) locked at the dead address on first deposit (blocks the share-inflation attack). Commit-reveal subsystem removed entirely (it bound nothing and was not atomic; see section 7). Converted to UUPS. `withdraw` is deliberately not pausable. Added `quoteSwap`, `sync`, three-way fee split. |
| `storage/LiquidityPoolStorage.sol` | Single storage layout inherited by every module and the main contract. | Rebuilt. Adds fee split fields, generic `PendingFee`/`PendingSplit` structs, `FeeType` enum, an abstract `_syncReserves()` hook so modules can resync, and a 40-slot `__gap`. Rule: modules must never declare state variables. |
| `modules/FeeController.sol` | Owner fee governance behind a 1-day timelock. | Generalized from three copy-pasted paths to one generic schedule/execute/cancel per `FeeType`, plus a dedicated path for the swap fee split (must sum to 100%). Hard caps enforced at schedule time: deposit burn <= 2%, withdraw fee <= 2%, swap fee <= 5%. v5 allowed scheduling 100% fees. |
| `modules/FeeManager.sol` | Moves earmarked balances out of the pool. | `withdrawProtocolFees` zeroes earmarks before transferring (CEI). `burnAccumulated` is now permissionless (anyone can crank the burn), attempts a true `burn(uint256)` on the token, verifies the balance actually decreased by the exact amount, and falls back to the dead address otherwise. |
| `libraries/MathUtils.sol` | Stateless math. | `getAmountOut` takes reserves as parameters and cannot read balances, making the v5 pricing bug impossible by construction. Single-division Uniswap V2 form (rounds in the pool's favor). Fixed a shadowed-return-variable compile error from v5. |
| `libraries/ERC20Utils.sol` | Non-standard-ERC20-tolerant transfers. | Was declared as a library but inherited as a contract in v5 (compile error). Now used via `using for`. Added `code.length` checks so a call to an EOA can never silently succeed. Custom errors. |
| `interfaces/IStakedTokenLP.sol` | Pool-side LP token interface. | Added the security warning that implementations must gate mint/burn to the pool. |
| `tokens/DeflationaryToken.sol` | The project token (fixed supply, transfer burn). | Production rewrite of the prototype. Hard `MAX_BURN_BPS` (10%) cap enforced in the token regardless of controller output (removes the honeypot surface). Controller call is gas-capped (100k) inside try/catch and fails open to zero tax (a broken controller can no longer freeze all transfers; the v5 prototype called the controller unconditionally with no constructor validation). Mints and burns skip the hook. Tax burns are true burns (`totalSupply` decreases) instead of dead-address parking. Inherits `ERC20Burnable`. Controller swaps are timelocked (1 day); scheduling `address(0)` disables the tax. `totalBurned()` is derived (`INITIAL_SUPPLY - totalSupply()`), removing a storage write from the transfer hot path. Sender-pays tax semantics preserved (load-bearing for AMM accounting). |
| `tokens/StakedTokenLP.sol` | LP share token. | `setMinter` is one-shot: reverts if already set, zero- and code-checked. The mock's owner-mutable minter was a pool-drain vector. |
| `tokens/FlatRateBurnController.sol` | Reference burn policy. | New. Flat rate (capped at 10% on its own side too) plus an owner-managed exemption list (exempt the pool to avoid tax stacking; exempt treasury/vesting). |

## 3. Default economic parameters

All adjustable post-deploy through the `FeeController` timelock, within hard caps.

| Parameter | Default | Hard cap | Destination |
|---|---|---|---|
| `depositBurnBps` | 10 (0.10%) | 200 (2%) | Earmarked, destroyed by burn crank |
| `withdrawFeeBps` | 25 (0.25%) | 200 (2%) | Stays in reserves (accrues to remaining LPs) |
| `swapFeeBps` | 100 (1.00%) | 500 (5%) | Split below |
| `swapFeeLpShareBps` | 5000 (50% of fee) | split sums to 100% | Stays in reserves (LP yield) |
| `swapFeeBurnShareBps` | 3000 (30% of fee) | split sums to 100% | Earmarked, destroyed by burn crank |
| `swapFeeProtocolShareBps` | 2000 (20% of fee) | split sums to 100% | Earmarked, owner-withdrawable |

Design note: v5 sent 100% of swap fees to the protocol, meaning LPs earned nothing and had no reason to provide liquidity. The LP share is what makes the pool economically viable. Consider scheduling `depositBurnBps` to 0; taxing liquidity provision works against pool depth, and the swap burn share will out-earn it.

## 4. Proxy (UUPS) implementation

### How it is wired

- Pattern: UUPS (ERC-1967 proxy, upgrade logic lives in the implementation). `AMMLiquidityPool` inherits `UUPSUpgradeable` and gates upgrades with `_authorizeUpgrade(...) onlyOwner`.
- The implementation constructor calls `_disableInitializers()`, so the raw implementation can never be initialized or hijacked.
- All initialization happens in `initialize(token0, token1, lpToken, owner)`, called once through the proxy (pass it as calldata when deploying the `ERC1967Proxy`).
- Storage safety rules, in order of importance:
  1. Every state variable lives in `LiquidityPoolStorage`. Modules hold constants, events, and functions only.
  2. `LiquidityPoolStorage` ends with `uint256[37] private __gap` (reduced from 40 when the three TWAP oracle slots were added, keeping the total footprint constant); new variables in future versions consume gap slots (append-only, never reorder, never change types, never insert).
  3. OpenZeppelin v5 upgradeable parents use ERC-7201 namespaced storage, so the diamond inheritance (both modules inherit `OwnableUpgradeable`) cannot collide.
- The token contracts are intentionally NOT upgradeable. A fixed-supply token whose rules can be swapped out is not fixed-supply in any meaningful sense; the pool is where iteration happens.

### Deployment order (runbook)

1. Deploy `DeflationaryToken` with `controller = address(0)` (tax off; avoids the chicken-and-egg since the controller may want addresses that do not exist yet).
2. Deploy `FlatRateBurnController` with the initial rate.
3. Deploy `StakedTokenLP`.
4. Deploy the `AMMLiquidityPool` implementation.
5. Deploy `ERC1967Proxy(implementation, abi.encodeCall(initialize, (token0, token1, lpToken, owner)))`.
6. `lpToken.setMinter(proxyAddress)`. One shot. The PROXY address, not the implementation.
7. Optional: `controller.setExempt(proxyAddress, true)` to avoid tax stacking on pool operations.
8. `token.scheduleControllerUpdate(controller)`, wait 1 day, `executeControllerUpdate()`. The tax goes live with built-in public notice.

### Upgrade procedure

1. Write `AMMLiquidityPoolV2` appending any new state into gap slots.
2. Validate layout: `forge inspect AMMLiquidityPoolV2 storage-layout` diffed against v1, or use the OpenZeppelin upgrades plugin which automates the check.
3. `upgradeToAndCall(newImplementation, migrationCalldata)` from the owner (use `""` if no migration function).

### Proxy testing (planned, none run yet)

- Initialization: cannot call `initialize` twice; cannot initialize the raw implementation; proxy state matches constructor-equivalent expectations.
- Authorization: non-owner `upgradeToAndCall` reverts.
- State survival: fork/deploy, seed reserves and earmarks, upgrade to a V2 mock, assert every storage field is unchanged and operations still work.
- Layout: automated storage-layout diff in CI (`openzeppelin-foundry-upgrades` validations or a `forge inspect` diff script).

## 5. Testing

### Current status

Honest accounting: **zero automated tests have been written or run, and the code has not been compiled** (authored in an offline environment without the OpenZeppelin packages). Verification so far is limited to careful manual review against a documented bug list from v5. The first action for anyone touching this repo is:

```bash
forge build
```

### Setup (Foundry)

```bash
curl -L https://foundry.paradigm.xyz | bash && foundryup
forge init --no-git .   # if starting the workspace fresh
forge install OpenZeppelin/openzeppelin-contracts@v5.1.0
forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.1.0
```

`remappings.txt`:

```
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
@openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/
```

Run everything:

```bash
forge test -vvv          # unit + fuzz
forge test --match-path test/invariant/* -vvv
forge coverage
```

### Planned test plan

Unit tests:
- Deposit: first deposit locks `MINIMUM_LIQUIDITY` at DEAD; proportional deposits mint `min()`; slippage guard; zero-amount reverts; deposit burn earmarked correctly.
- Withdraw: pro-rata amounts; exit fee stays in reserves; works while paused; reverts on `supply == 0`.
- Swap: both directions; fee split adds up (`lpCut + burnCut + protocolCut == feeAmount`); slippage and deadline guards; `quoteSwap` matches realized output for vanilla tokens.
- FeeController: caps enforced at schedule time; timelock enforced; cancel works; split must sum to 100%.
- FeeManager: protocol withdrawal zeroes earmarks; permissionless `burnAccumulated` takes the true-burn path for `DeflationaryToken` and the DEAD path for a vanilla mock.
- DeflationaryToken: tax clamped at 10% for a malicious controller returning `type(uint256).max`; reverting controller yields 0 tax and transfers succeed; gas-bomb controller yields 0 tax; mints/burns untaxed; timelocked controller swap; `totalBurned` identity.
- StakedTokenLP: second `setMinter` reverts; non-minter mint/burn reverts.

Regression tests (each maps to a fixed v5 bug):
- Pricing: pool 1000/1000, swap 100 in at 1% fee, assert output ~90.08 (v5 returned ~83).
- Inflation attack: 1-wei first deposit plus donation must not let the attacker steal the second depositor's funds.
- Fee-on-transfer deposit: deposit `DeflationaryToken` with tax active and a non-exempt sender; LP minted must reflect received (post-tax) amounts.

Invariant / property tests (forge invariant fuzzing):
- `reserve0 == token0.balanceOf(pool) - burnToken0 - feeToken0` after every operation (and same for token1).
- k (net of fees) never decreases from swaps.
- LP share value (reserves per LP token) never decreases due to other users' deposits/withdrawals.
- `DeflationaryToken.totalSupply()` is monotonically non-increasing after construction.
- Pool never reverts on `_syncReserves` underflow under any operation sequence (with supported tokens).

Proxy tests: section 4.

Phase 0 additions to the plan:
- Oracle: accumulators advance by spot price x elapsed time across operations; no accumulation within the same timestamp; accumulation uses PRE-operation reserves; reserves >= 2^144 skip accumulation without reverting; overflow wrap of a cumulative price still yields correct deltas.
- Permit: EIP-2612 signature flow approves and executes a deposit/swap without a prior approve transaction, on both tokens.
- Two-step ownership: `transferOwnership` alone does not change the owner; `acceptOwnership` from the pending owner does; the pattern applies to the pool (upgradeable) and `DeflationaryToken`.
- Custom errors: revert assertions use error selectors and decoded data (e.g. `SlippageExceeded` carries the actual and minimum amounts).

## 6. Roadmap (EVM committed; Solana is a later port)

Chain decision (2026-07-03): build and ship on EVM. A Solana port is a separate, later milestone. The invariant test suite doubles as the port's chain-agnostic spec, so effort spent on Phase 2 transfers.

Ordering principle: parts of this system freeze at different moments, and changes are cheap only before the relevant freeze. The token contracts freeze permanently at deployment (immutable). The pool's ABI and storage effectively freeze once the test suite encodes them. Everything freezes at audit. Therefore any improvement touching contract surface (inheritance, storage layout, ABI, error selectors) is promoted into Phase 0, and improvements that touch nothing frozen are deliberately deferred (section 7).

### Phase 0: freeze the contract surface (improvements promoted from the old suggestions list)

Status: items 1-4 COMPLETE (2026-07-03). Item 5 awaits a product decision.

1. **[DONE] EIP-2612 permit** on `DeflationaryToken` AND `StakedTokenLP` (gasless approvals; LP permit also serves future router flows). The tokens are immutable; this was now or never.
2. **[DONE] `Ownable2Step`** on `DeflationaryToken` and the pool (`Ownable2StepUpgradeable`). `StakedTokenLP` deliberately keeps plain `Ownable`: its ownership has no powers after the one-shot `setMinter`, and renouncing is the intended end state.
3. **[DONE] Custom errors everywhere.** All require strings converted across the pool, modules, `MathUtils`, and tokens. Several errors carry data (`SlippageExceeded(actual, minimum)`, `TimelockActive(executeAfter)`, `FeeAboveCap(requested, cap)`); the frontend handoff error table is updated to match.
4. **[DONE] TWAP oracle accumulators.** `price0CumulativeLast` / `price1CumulativeLast` (Q112, overflow-wrapping by design) plus `blockTimestampLast`, accumulated in `_syncReserves` with the reserves that prevailed since the previous sync (Uniswap V2 semantics). Accumulation is skipped for reserves >= 2^144 to rule out mul overflow without ever reverting. Storage gap reduced 40 -> 37 to keep the layout footprint constant.
5. **[PENDING DECISION] Scope the router/zap** (decision only; build in Phase 3). Periphery, does not block the core, but the audit must be scoped with or without it. Recommendation: in scope, audited together with the core.

### Phase 1: build and guardrails

6. `forge build`; fix whatever the compiler finds (candidate: the `override` specifier list on `DeflationaryToken._update` depending on exact OZ version).
7. **CI from day one**: GitHub Actions running `forge build`, `forge test`, `forge coverage`, `slither`, and a storage-layout diff on every PR. Promoted because every later phase is cheaper with it in place.

### Phase 2: verification

8. Implement the test plan in section 5. The regression trio is the priority. Write invariants chain-agnostically where possible: they are also the Solana port spec.
9. Static analysis: `slither .` and triage findings.

### Phase 3: parameters and periphery

10. Decide `depositBurnBps` (recommendation: 0) and the final fee split before liquidity seeding.
11. Deployment scripts (`forge script`) encoding the runbook in section 4, including a full testnet dry run.
12. Build the router/zap on a parallel track; it joins the audit scope.

### Phase 4: hardening and launch

13. Move ownership of pool, token, and LP token to a multisig before any real value; a single EOA owner undermines every timelock in the system.
14. Professional audit (core plus periphery together). This code is unaudited.
15. Frontend build against the testnet deployment (see `docs/frontend/HANDOFF-FRONTEND.md`; tax-adjusted quoting and proportional deposit amounts are rules U1 and U2 there).

### Phase 5: later milestone

16. Solana port: reuse the invariant spec; port the economic core (pricing, liquidity math, fee split, burn crank) to Anchor. The commit-reveal removal already deleted the least portable subsystem.

## 7. Deliberately deferred improvements

Each of these touches nothing that freezes, or has an escape hatch, so deferring is a choice rather than an oversight:

- **Timelock on `FlatRateBurnController.setBurnRate`.** The controller is swappable behind the token's own 1-day timelock, so a hardened v2 controller can replace it at any time without touching the token.
- **Indexer/subgraph** for the burn feed. Raw `eth_getLogs` suffices for v1 (handoff section 2); revisit if event volume grows.
- **Known-limitations user documentation** (rebasing/reflection tokens unsupported, `quoteSwap` is tax-blind, donations absorb into reserves at next `sync`). Write alongside the frontend, where the words will actually be read.

## 8. Provenance

v6 is a ground-up rewrite following a review of v5 that found, among other things: a swap-pricing bug that double-counted the input (users received materially less than fair output), a missing minimum-liquidity lock (first-depositor inflation attack), non-delta-based deposit accounting (unsafe for fee-on-transfer tokens), a commit-reveal scheme that neither bound the revealed parameters to the executed swap nor executed atomically (no MEV protection in practice), unbounded owner-settable fees, and a set of compile errors from a half-merged migration between a monolith and the module system. Section 2 maps each fix to its file.
