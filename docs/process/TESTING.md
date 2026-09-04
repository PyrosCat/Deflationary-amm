# Testing with Foundry (Forge)

A step-by-step guide for this repo, written for someone coming from Hardhat. Covers setup, the Hardhat-to-Foundry mental model, the cheatcodes this suite uses, how to run everything, and a map of which test file covers which part of the README test plan.

**Status: the suite (7 files, ~1,070 lines) is written but has NOT been executed** — it was authored in an offline environment. Expect the first `forge build` to surface small fixups (see section 11 for likely candidates and how to triage).

---

## 1. Why Forge, coming from Hardhat

Tests are written in Solidity, not JavaScript. That sounds like a downside until you feel the consequences: no ABI boundary (call contracts directly, custom errors and structs just work), execution is 10-100x faster, and two test types Hardhat has no native answer for come built in — fuzz tests (randomized inputs against a property) and invariant tests (randomized *call sequences* against a property). For an AMM, invariant testing is the single highest-value tool: it is how you find the weird op-ordering that breaks reserve accounting.

What you give up: JS ecosystem glue in tests. Deployment scripting exists (`forge script`, also Solidity) and both toolchains can coexist in one repo if you ever want Hardhat back for something.

## 2. Install

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
forge --version   # verify
```

`foundryup` installs `forge` (build/test), `cast` (CLI chain interactions), `anvil` (local node, the Hardhat Network equivalent), and `chisel` (Solidity REPL).

## 3. Repo layout

Already committed:

```
foundry.toml       compiler + test config (src = contracts, test = test)
remappings.txt     import path mappings (@openzeppelin/... -> lib/...)
test/
├── helpers/TestBase.sol           shared deployment + mocks + helpers
├── Pool.t.sol                     deposit / withdraw / swap / pause / oracle
├── Tokens.t.sol                   DeflationaryToken + StakedTokenLP
├── Governance.t.sol               FeeController + FeeManager + 2-step ownership
├── Regression.t.sol               the three v5 bug regressions
├── Proxy.t.sol                    UUPS behavior + upgrade state survival
└── invariant/PoolInvariants.t.sol handler-based invariant suite
```

Conventions Forge relies on: test files end in `.t.sol`; test functions start with `test_` (unit), `testFuzz_` (fuzz — any function with parameters is fuzzed automatically), or `invariant_` (invariant properties).

## 4. Install dependencies

Foundry uses git submodules in `lib/`, not npm:

```bash
cd amm-v6
git init   # if not already a repo (forge install requires git)
forge install foundry-rs/forge-std
forge install OpenZeppelin/openzeppelin-contracts@v5.1.0
forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.1.0
```

The committed `remappings.txt` maps the `@openzeppelin/...` imports (unchanged from the Hardhat days) onto `lib/`. If imports fail, run `forge remappings` to see what Forge resolved and compare.

## 5. First build

```bash
forge build
```

This is milestone zero for the whole project (README Phase 1). Fix what it finds before anything else.

## 6. Hardhat -> Foundry translation table

| Hardhat | Foundry |
|---|---|
| `describe("Pool", ...)` | `contract PoolTest is Test { ... }` |
| `it("swaps", async ...)` | `function test_Swap() public { ... }` |
| `beforeEach` | `function setUp() public { ... }` (fresh state per test) |
| fixtures / `loadFixture` | inheritance: shared `setUp` in a base contract (`PoolTestBase`) |
| `expect(x).to.equal(y)` | `assertEq(x, y, "label")` |
| `expect(tx).to.be.revertedWithCustomError(c, "Err")` | `vm.expectRevert(C.Err.selector)` before the call |
| ...`.withArgs(a, b)` | `vm.expectRevert(abi.encodeWithSelector(C.Err.selector, a, b))` |
| `expect(tx).to.emit(c, "Event")` | `vm.expectEmit(...)` then emit the expected event, then the call |
| `ethers.getSigners()` | `makeAddr("alice")`, or `makeAddrAndKey` when you need to sign |
| `contract.connect(alice).f()` | `vm.prank(alice); contract.f();` (`startPrank`/`stopPrank` for spans) |
| `evm_increaseTime` / `evm_mine` | `vm.warp(t)` / `vm.roll(n)` |
| `setBalance`, dealing tokens | `vm.deal(addr, eth)`; for ERC20s just call your mock's `mint` |
| `console.log` | `console.log` (`import "forge-std/console.sol"`), shown at `-vv`+ |
| `ethers.provider.send(...)` hacks | usually a first-class cheatcode — check the Foundry book |

The mental shift: your test contract IS an account on the chain. `address(this)` deploys, holds tokens, and is `msg.sender` unless you prank.

## 7. Anatomy of this suite

Everything pool-related inherits `PoolTestBase` (`test/helpers/TestBase.sol`), whose `setUp` deploys the real system the way production will run: implementation, then an `ERC1967Proxy` carrying the `initialize` calldata, then the one-shot `lp.setMinter(proxy)`. Tests always talk to the proxy — meaning every single test also exercises the delegatecall path for free.

The base also provides: two funded/approved users (`alice`, `bob`), mirror-math helpers (`_quoteOut`, `_netOfDepositBurn`) so expected values are computed independently in the test rather than read back from the contract, an EIP-2612 signing helper, and three hostile burn controllers (`MaxTaxController`, `RevertingController`, `GasBombController`) used to prove the token's clamp and fail-open guarantees.

## 8. Cheatcodes used here, with the exact patterns

**Impersonation** — `vm.prank(alice)` applies to the next call only:

```solidity
vm.prank(alice);
pool.deposit(1000e18, 1000e18, 0, block.timestamp + 1);
```

**Custom errors, selector only** (errors without data):

```solidity
vm.expectRevert(AMMLiquidityPool.Expired.selector);
```

**Custom errors with data** — this suite asserts the *contents* of data-carrying errors, which doubles as the Phase 0 "errors carry data" test:

```solidity
vm.expectRevert(
    abi.encodeWithSelector(AMMLiquidityPool.SlippageExceeded.selector, expected, expected + 1)
);
```

**Time** — `vm.warp` drives both the fee timelock and the TWAP oracle tests:

```solidity
vm.warp(block.timestamp + pool.FEE_UPDATE_DELAY());
```

**Signing** — `makeAddrAndKey` + `vm.sign` produce a real EIP-2612 permit signature with no wallet involved (see `_signPermit` in the base and the permit tests in `Tokens.t.sol`).

## 9. Running

```bash
forge test                                   # everything
forge test -vvv                              # show traces for failures
forge test --match-path test/Regression.t.sol
forge test --match-test test_Regression      # by test name pattern
forge test --match-contract PoolInvariants   # just the invariant suite
forge test --gas-report                      # per-function gas table
forge coverage                               # line/branch coverage
forge snapshot                               # gas snapshot file for diffing
```

Verbosity: `-vv` shows logs, `-vvv` adds traces for failing tests, `-vvvv` traces everything.

## 10. Fuzz and invariant testing (the part Hardhat doesn't have)

**Fuzz**: any test function with parameters gets called with 256 random inputs (config in `foundry.toml`). Use `bound(x, lo, hi)` to constrain, not `vm.assume`, which discards runs. Example here: `testFuzz_TaxNeverExceedsHardCap` proves the 10% clamp for every transfer amount against a controller returning `uint256.max`.

**Invariant**: Forge generates random SEQUENCES of calls, then checks every `invariant_` function after each one. Raw fuzzing against the pool would mostly generate garbage reverts, so the suite uses the standard **handler pattern**: `PoolHandler` is the only fuzz target (`targetContract(address(handler))`), and its methods bound inputs into meaningful ranges (deposits that pass minimum liquidity, swaps at most half the reserve) and record **ghost state** for cross-call properties. The four invariants:

1. `reserve == balance − earmarks` for both tokens (the load-bearing accounting identity)
2. earmarked funds are always actually present
3. `MINIMUM_LIQUIDITY` stays locked once liquidity exists
4. no swap in any sequence ever decreased k net of fees (via the handler's ghost flag)

Config: 64 runs x depth 32 (~2,000 random op sequences) with `fail_on_revert = false` so bound-edge reverts inside the handler don't abort the campaign. Crank these numbers up for a serious overnight run.

## 11. Status, and triaging the first build

Nothing in `test/` has been executed. Realistic first-build friction, in order of likelihood: (1) remapping/lib-version mismatches — check `forge remappings` and that both OZ packages are v5.x; (2) the `override` specifier list on `DeflationaryToken._update` — the compiler error will state the exact list to write; (3) the pool's inheritance linearization with `Ownable2StepUpgradeable` — if solc complains, reorder the base list; (4) small assertion-value drift where a test hardcodes a number instead of mirroring contract math. None of these change what the tests *mean*; they are mechanical fixes.

Suggested first session: `forge build` -> fix -> `forge test --match-path test/Regression.t.sol -vvv` (the three tests that prove the v5 bugs are dead) -> full `forge test` -> `forge coverage`.

## 12. Suite map (README test plan -> files)

| README plan item | Where |
|---|---|
| Deposit units (min-liquidity lock, min() semantics, slippage data, zero amount) | `Pool.t.sol` |
| Withdraw units (pro-rata minus exit fee, fee accrues to remaining LPs, works while paused) | `Pool.t.sol` |
| Swap units (formula/quote match both directions, fee split accounting, deadline, invalid token) | `Pool.t.sol` |
| Oracle (accumulation, same-timestamp, pre-trade weighting, overflow-bound skip) | `Pool.t.sol` |
| FeeController (caps with error data, timelock, cancel, split sum, onlyOwner) | `Governance.t.sol` |
| FeeManager (fee withdrawal, permissionless crank, dead path AND true-burn path) | `Governance.t.sol` |
| Pool two-step ownership | `Governance.t.sol` |
| DeflationaryToken (clamp, fail-open, gas bomb, untaxed burns, timelock, 2-step, permit, fuzz) | `Tokens.t.sol` |
| StakedTokenLP (one-shot minter, guards, minter-only mint/burn) | `Tokens.t.sol` |
| Regression trio (v5 pricing, inflation attack, fee-on-transfer deposit) | `Regression.t.sol` |
| Proxy (init-once, impl lockout, upgrade auth, full state survival) | `Proxy.t.sol` |
| Invariants (accounting identity, solvency, locked minimum, k monotonic on swaps) | `invariant/PoolInvariants.t.sol` |

## 13. CI (README Phase 1, item 7)

`.github/workflows/test.yml`:

```yaml
name: test
on: [push, pull_request]
jobs:
  forge:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { submodules: recursive }
      - uses: foundry-rs/foundry-toolchain@v1
      - run: forge build --sizes
      - run: forge test -vvv
      - run: forge coverage --report summary
```

Add a `slither .` job and a storage-layout diff step (`forge inspect AMMLiquidityPool storage-layout`) once the build is green.
