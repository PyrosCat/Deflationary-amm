// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolTestBase} from "./helpers/TestBase.sol";
import {AMMLiquidityPool} from "../contracts/AMMLiquidityPool.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// Unit tests: deposit, withdraw, swap, pause behavior, TWAP oracle.
contract PoolTest is PoolTestBase {
    // ─── Deposit ────────────────────────────────────────────────────────

    function test_FirstDeposit_LocksMinimumLiquidity() public {
        uint256 liq = _seed(1000e18, 1000e18);
        uint256 net = _netOfDepositBurn(1000e18); // 999e18

        assertEq(liq, net - pool.MINIMUM_LIQUIDITY(), "alice liquidity");
        assertEq(lp.balanceOf(pool.DEAD()), pool.MINIMUM_LIQUIDITY(), "locked LP");
        assertEq(pool.reserve0(), net, "reserve0");
        assertEq(pool.reserve1(), net, "reserve1");
        assertEq(pool.burnToken0(), 1000e18 - net, "deposit burn earmarked");
    }

    function test_Deposit_MinSemantics_ExcessAbsorbed() public {
        _seed(1000e18, 1000e18);
        uint256 supply = lp.totalSupply();
        uint256 r0 = pool.reserve0();
        uint256 r1 = pool.reserve1();

        uint256 net0 = _netOfDepositBurn(100e18);
        uint256 net1 = _netOfDepositBurn(50e18);
        uint256 side0 = (net0 * supply) / r0;
        uint256 side1 = (net1 * supply) / r1;
        uint256 expected = side0 < side1 ? side0 : side1;

        vm.prank(bob);
        uint256 liq = pool.deposit(100e18, 50e18, 0, block.timestamp + 1);

        assertEq(liq, expected, "LP minted on min() side");
        assertEq(pool.reserve0(), r0 + net0, "excess token0 absorbed into reserves");
    }

    function test_Deposit_SlippageRevertsWithData() public {
        _seed(1000e18, 1000e18);
        uint256 supply = lp.totalSupply();
        uint256 net = _netOfDepositBurn(100e18);
        uint256 expected = (net * supply) / pool.reserve0();

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(AMMLiquidityPool.SlippageExceeded.selector, expected, expected + 1)
        );
        pool.deposit(100e18, 100e18, expected + 1, block.timestamp + 1);
    }

    function test_Deposit_ZeroAmountReverts() public {
        vm.prank(alice);
        vm.expectRevert(AMMLiquidityPool.ZeroAmount.selector);
        pool.deposit(0, 1e18, 0, block.timestamp + 1);
    }

    // ─── Withdraw ───────────────────────────────────────────────────────

    function test_Withdraw_ProRataMinusExitFee() public {
        uint256 liq = _seed(1000e18, 1000e18);
        uint256 supply = lp.totalSupply();
        uint256 r0 = pool.reserve0();

        uint256 half = liq / 2;
        uint256 gross = (r0 * half) / supply;
        uint256 expectedOut = gross - (gross * pool.withdrawFeeBps()) / BPS;

        uint256 balBefore = tokenA.balanceOf(alice);
        vm.prank(alice);
        (uint256 out0,) = pool.withdraw(half, 0, 0, block.timestamp + 1);

        assertEq(out0, expectedOut, "returned amount");
        assertEq(tokenA.balanceOf(alice) - balBefore, expectedOut, "tokens received");
    }

    function test_Withdraw_ExitFeeAccruesToRemainingLPs() public {
        uint256 aliceLiq = _seed(1000e18, 1000e18);
        vm.prank(bob);
        uint256 bobLiq = pool.deposit(1000e18, 1000e18, 0, block.timestamp + 1);

        uint256 bobValueBefore = (pool.reserve0() * bobLiq) / lp.totalSupply();

        vm.prank(alice);
        pool.withdraw(aliceLiq, 0, 0, block.timestamp + 1);

        uint256 bobValueAfter = (pool.reserve0() * bobLiq) / lp.totalSupply();
        assertGt(bobValueAfter, bobValueBefore, "exit fee raised remaining LP share value");
    }

    function test_Withdraw_WorksWhilePaused_OthersBlocked() public {
        uint256 liq = _seed(1000e18, 1000e18);
        vm.prank(owner);
        pool.pause();

        vm.prank(bob);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        pool.swap(address(tokenA), 1e18, 0, block.timestamp + 1);

        vm.prank(bob);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        pool.deposit(1e18, 1e18, 0, block.timestamp + 1);

        vm.prank(alice);
        pool.withdraw(liq / 2, 0, 0, block.timestamp + 1); // must not revert
    }

    // ─── Swap ───────────────────────────────────────────────────────────

    function test_Swap_MatchesQuoteAndFormula_BothDirections() public {
        _seed(1000e18, 1000e18);

        uint256 r0 = pool.reserve0();
        uint256 r1 = pool.reserve1();
        uint256 quoted = pool.quoteSwap(address(tokenA), 10e18);
        vm.prank(bob);
        uint256 outAB = pool.swap(address(tokenA), 10e18, 0, block.timestamp + 1);
        assertEq(outAB, quoted, "swap matches quote (vanilla tokens)");
        assertEq(outAB, _quoteOut(10e18, r0, r1), "swap matches formula");

        r0 = pool.reserve0();
        r1 = pool.reserve1();
        vm.prank(bob);
        uint256 outBA = pool.swap(address(tokenB), 10e18, 0, block.timestamp + 1);
        assertEq(outBA, _quoteOut(10e18, r1, r0), "reverse direction");
    }

    function test_Swap_FeeSplitAccounting() public {
        _seed(1000e18, 1000e18);
        uint256 r0 = pool.reserve0();
        uint256 r1 = pool.reserve1();
        uint256 kBefore = r0 * r1;
        uint256 burnBefore = pool.burnToken0();
        uint256 protoBefore = pool.feeToken0();

        uint256 amountIn = 10e18;
        uint256 fee = (amountIn * pool.swapFeeBps()) / BPS;
        uint256 burnCut = (fee * pool.swapFeeBurnShareBps()) / BPS;
        uint256 protoCut = (fee * pool.swapFeeProtocolShareBps()) / BPS;

        vm.prank(bob);
        uint256 out = pool.swap(address(tokenA), amountIn, 0, block.timestamp + 1);

        assertEq(pool.burnToken0() - burnBefore, burnCut, "burn cut earmarked");
        assertEq(pool.feeToken0() - protoBefore, protoCut, "protocol cut earmarked");
        assertEq(pool.reserve0(), r0 + amountIn - burnCut - protoCut, "lp cut stays in reserves");
        assertEq(pool.reserve1(), r1 - out, "output left reserves");
        assertGe(pool.reserve0() * pool.reserve1(), kBefore, "k non-decreasing net of fees");
    }

    function test_Swap_SlippageRevertsWithData() public {
        _seed(1000e18, 1000e18);
        uint256 expected = pool.quoteSwap(address(tokenA), 10e18);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(AMMLiquidityPool.SlippageExceeded.selector, expected, expected + 1)
        );
        pool.swap(address(tokenA), 10e18, expected + 1, block.timestamp + 1);
    }

    function test_Swap_ExpiredDeadlineReverts() public {
        _seed(1000e18, 1000e18);
        uint256 deadline = block.timestamp;
        vm.warp(block.timestamp + 10);

        vm.prank(bob);
        vm.expectRevert(AMMLiquidityPool.Expired.selector);
        pool.swap(address(tokenA), 1e18, 0, deadline);
    }

    function test_Swap_InvalidTokenReverts() public {
        _seed(1000e18, 1000e18);
        vm.prank(bob);
        vm.expectRevert(AMMLiquidityPool.InvalidToken.selector);
        pool.swap(makeAddr("random"), 1e18, 0, block.timestamp + 1);
    }

    // ─── TWAP oracle ────────────────────────────────────────────────────

    function test_Oracle_AccumulatesSpotTimesElapsed() public {
        _seed(1000e18, 1000e18);
        uint256 r0 = pool.reserve0();
        uint256 r1 = pool.reserve1();
        assertEq(pool.price0CumulativeLast(), 0, "no accumulation before reserves existed");

        vm.warp(block.timestamp + 100);
        pool.sync();

        assertEq(pool.price0CumulativeLast(), ((r1 * Q112) / r0) * 100, "price0 accumulated");
        assertEq(pool.price1CumulativeLast(), ((r0 * Q112) / r1) * 100, "price1 accumulated");
    }

    function test_Oracle_NoDoubleAccumulationSameTimestamp() public {
        _seed(1000e18, 1000e18);
        vm.warp(block.timestamp + 100);
        pool.sync();
        uint256 p0 = pool.price0CumulativeLast();

        pool.sync(); // same timestamp
        assertEq(pool.price0CumulativeLast(), p0, "no second accumulation in same second");
    }

    function test_Oracle_UsesPreTradeReserves() public {
        _seed(1000e18, 1000e18);
        uint256 r0 = pool.reserve0();
        uint256 r1 = pool.reserve1();

        vm.warp(block.timestamp + 50);
        vm.prank(bob);
        pool.swap(address(tokenA), 100e18, 0, block.timestamp + 1); // triggers sync

        assertEq(
            pool.price0CumulativeLast(),
            ((r1 * Q112) / r0) * 50,
            "accumulation weighted by the PRE-swap price"
        );
    }

    function test_Oracle_SkipsHugeReservesWithoutReverting() public {
        _seed(1000e18, 1000e18);
        tokenA.mint(address(pool), 2 ** 150); // donation pushes reserve0 past 2**144
        pool.sync(); // accumulates with OLD (small) reserves, then stores huge reserve0

        uint256 p0 = pool.price0CumulativeLast();
        vm.warp(block.timestamp + 100);
        pool.sync(); // must neither revert nor accumulate

        assertEq(pool.price0CumulativeLast(), p0, "accumulation skipped above the safety bound");
    }
}
