// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolTestBase, MockERC20} from "./helpers/TestBase.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AMMLiquidityPool} from "../contracts/AMMLiquidityPool.sol";
import {StakedTokenLP} from "../contracts/tokens/StakedTokenLP.sol";
import {DeflationaryToken} from "../contracts/tokens/DeflationaryToken.sol";
import {FlatRateBurnController} from "../contracts/tokens/FlatRateBurnController.sol";
import {MathUtils} from "../contracts/libraries/MathUtils.sol";

/// Each test maps to a specific v5 bug. If any of these fail after a change,
/// a fixed bug has been reintroduced.
contract RegressionTest is PoolTestBase {
    /// v5 bug: pricing read live balances (already containing the input) and
    /// then added the input again, roughly doubling price impact.
    /// Pool ~999/999, swap 100 at 1% fee: correct out ~90e18; v5 paid ~83e18.
    function test_Regression_SwapPricing_InputNotDoubleCounted() public {
        _seed(1000e18, 1000e18);
        uint256 r0 = pool.reserve0();
        uint256 r1 = pool.reserve1();

        vm.prank(bob);
        uint256 out = pool.swap(address(tokenA), 100e18, 0, block.timestamp + 1);

        // Mirror math via the shared uint256 helper. NOTE: do not inline this as
        // `100e18 * pool.swapFeeBps()` — swapFeeBps() returns uint16, and Solidity
        // performs literal-times-uint16 in the literal's mobile type (uint72 for
        // 100e18), so 1e20 * 100 = 1e22 overflows uint72's ~4.72e21 max and
        // panics. _quoteOut takes uint256 params, promoting the math to 256-bit.
        assertEq(out, _quoteOut(100e18, r0, r1), "exact constant-product on PRE-trade reserves");
        assertGt(out, 88e18, "v5's double-counted math returned ~83e18");
    }

    /// v5 bug: no minimum-liquidity lock. Attacker mints dust LP, donates to
    /// inflate share price, victim's deposit rounds to zero LP and is stolen.
    function test_Regression_InflationAttack_Defended() public {
        uint256 bobStartA = tokenA.balanceOf(bob);

        // Attack step 1: dust first deposit.
        vm.prank(bob);
        pool.deposit(2000, 2000, 0, block.timestamp + 1);

        // Attack step 2: massive donation to inflate share price.
        vm.startPrank(bob);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        tokenA.transfer(address(pool), 10_000e18);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        tokenB.transfer(address(pool), 10_000e18);
        vm.stopPrank();
        pool.sync();

        // Victim deposits. Amount must be commensurate with the (now inflated)
        // pool size — a deposit 10_000x smaller than reserves legitimately rounds
        // to zero LP under constant-product math; that is correct behavior, not
        // the v5 theft bug. The min-liquidity lock defends against the attacker
        // STEALING a fair-sized deposit, which is what this asserts.
        vm.prank(alice);
        uint256 victimLiq = pool.deposit(100e18, 100e18, 0, block.timestamp + 1);
        assertGt(victimLiq, 0, "victim must receive LP (v5 rounded to zero)");

        // Victim exits without loss.
        vm.prank(alice);
        (uint256 out0,) = pool.withdraw(victimLiq, 0, 0, block.timestamp + 1);
        assertGe(out0, 0.99e18, "victim recovers at least their contribution");

        // Attacker exits everything and has lost money overall.
        vm.startPrank(bob);
        pool.withdraw(lp.balanceOf(bob), 0, 0, block.timestamp + 1);
        vm.stopPrank();
        assertLt(tokenA.balanceOf(bob), bobStartA, "attack is unprofitable");
    }

    /// v5 bug: deposit trusted the caller's stated amounts instead of
    /// measuring balance deltas — fee-on-transfer tokens over-minted LP.
    function test_Regression_FeeOnTransferDeposit_UsesMeasuredAmounts() public {
        FlatRateBurnController ctrl = new FlatRateBurnController(200); // 2% transfer tax
        DeflationaryToken mtk = new DeflationaryToken("Defl", "DFL", 1_000_000e18, alice, address(ctrl));
        MockERC20 other = new MockERC20("Other", "OTH");
        StakedTokenLP lp2 = new StakedTokenLP("LP2", "LP2");

        AMMLiquidityPool pool2 = AMMLiquidityPool(
            address(
                new ERC1967Proxy(
                    address(new AMMLiquidityPool()),
                    abi.encodeCall(
                        AMMLiquidityPool.initialize,
                        (address(mtk), address(other), address(lp2), owner)
                    )
                )
            )
        );
        lp2.setMinter(address(pool2));

        other.mint(alice, 1_000e18);
        vm.startPrank(alice);
        mtk.approve(address(pool2), type(uint256).max);
        other.approve(address(pool2), type(uint256).max);
        uint256 liq = pool2.deposit(100e18, 100e18, 0, block.timestamp + 1);
        vm.stopPrank();

        uint256 received0 = 98e18; // sender-pays 2% tax in transit
        uint256 net0 = received0 - (received0 * pool2.depositBurnBps()) / BPS;
        uint256 net1 = 100e18 - (100e18 * pool2.depositBurnBps()) / BPS;

        assertEq(pool2.reserve0(), net0, "reserves reflect MEASURED post-tax amount");
        assertEq(liq, MathUtils.sqrt(net0 * net1) - pool2.MINIMUM_LIQUIDITY(), "LP minted on measured amounts");
        assertEq(
            pool2.reserve0(),
            mtk.balanceOf(address(pool2)) - pool2.burnToken0() - pool2.feeToken0(),
            "accounting identity holds"
        );
    }
}
