// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolTestBase, MockERC20} from "./helpers/TestBase.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {AMMLiquidityPool} from "../contracts/AMMLiquidityPool.sol";
import {FeeController} from "../contracts/modules/FeeController.sol";
import {FeeManager} from "../contracts/modules/FeeManager.sol";
import {LiquidityPoolStorage} from "../contracts/storage/LiquidityPoolStorage.sol";
import {StakedTokenLP} from "../contracts/tokens/StakedTokenLP.sol";
import {DeflationaryToken} from "../contracts/tokens/DeflationaryToken.sol";

/// FeeController (timelocked governance), FeeManager (fees + burn crank),
/// and pool-level two-step ownership.
contract GovernanceTest is PoolTestBase {
    // ─── FeeController ──────────────────────────────────────────────────

    function test_ScheduleAboveCap_RevertsWithData() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FeeController.FeeAboveCap.selector, uint16(600), uint16(500)));
        pool.scheduleFeeUpdate(LiquidityPoolStorage.FeeType.SwapFee, 600);
    }

    function test_ExecuteBeforeDelay_RevertsWithUnlockTime() public {
        uint64 unlock = uint64(block.timestamp + pool.FEE_UPDATE_DELAY());
        vm.startPrank(owner);
        pool.scheduleFeeUpdate(LiquidityPoolStorage.FeeType.SwapFee, 200);

        vm.expectRevert(abi.encodeWithSelector(FeeController.TimelockActive.selector, unlock));
        pool.executeFeeUpdate(LiquidityPoolStorage.FeeType.SwapFee);
        vm.stopPrank();
    }

    function test_FeeUpdate_Lifecycle() public {
        vm.startPrank(owner);
        pool.scheduleFeeUpdate(LiquidityPoolStorage.FeeType.SwapFee, 200);

        (uint16 newBps,, bool exists) = pool.pendingFees(uint8(LiquidityPoolStorage.FeeType.SwapFee));
        assertTrue(exists);
        assertEq(newBps, 200);

        vm.warp(block.timestamp + pool.FEE_UPDATE_DELAY());
        pool.executeFeeUpdate(LiquidityPoolStorage.FeeType.SwapFee);
        vm.stopPrank();

        assertEq(pool.swapFeeBps(), 200, "fee applied after timelock");
        (,, exists) = pool.pendingFees(uint8(LiquidityPoolStorage.FeeType.SwapFee));
        assertFalse(exists, "pending cleared");
    }

    function test_Cancel_ClearsPending() public {
        vm.startPrank(owner);
        pool.scheduleFeeUpdate(LiquidityPoolStorage.FeeType.WithdrawFee, 50);
        pool.cancelFeeUpdate(LiquidityPoolStorage.FeeType.WithdrawFee);

        vm.expectRevert(FeeController.NoPendingUpdate.selector);
        pool.executeFeeUpdate(LiquidityPoolStorage.FeeType.WithdrawFee);
        vm.stopPrank();
    }

    function test_Split_MustSumTo100() public {
        vm.startPrank(owner);
        vm.expectRevert(FeeController.SplitMustSumTo100.selector);
        pool.scheduleSplitUpdate(5000, 5000, 1000);

        pool.scheduleSplitUpdate(4000, 4000, 2000);
        vm.warp(block.timestamp + pool.FEE_UPDATE_DELAY());
        pool.executeSplitUpdate();
        vm.stopPrank();

        assertEq(pool.swapFeeLpShareBps(), 4000);
        assertEq(pool.swapFeeBurnShareBps(), 4000);
        assertEq(pool.swapFeeProtocolShareBps(), 2000);
    }

    function test_Governance_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        pool.scheduleFeeUpdate(LiquidityPoolStorage.FeeType.SwapFee, 200);
    }

    function test_Pool_TwoStepOwnership() public {
        vm.prank(owner);
        pool.transferOwnership(bob);
        assertEq(pool.owner(), owner, "transfer alone does not change owner");
        assertEq(pool.pendingOwner(), bob);

        vm.prank(bob);
        pool.acceptOwnership();
        assertEq(pool.owner(), bob);
    }

    // ─── FeeManager ─────────────────────────────────────────────────────

    function test_WithdrawProtocolFees_TransfersAndZeroes() public {
        _seed(10_000e18, 10_000e18);
        vm.prank(bob);
        pool.swap(address(tokenA), 1_000e18, 0, block.timestamp + 1);

        uint256 accrued = pool.feeToken0();
        assertGt(accrued, 0);
        uint256 r0 = pool.reserve0();
        address treasury = makeAddr("treasury");

        vm.prank(owner);
        pool.withdrawProtocolFees(treasury);

        assertEq(tokenA.balanceOf(treasury), accrued, "fees delivered");
        assertEq(pool.feeToken0(), 0, "earmark zeroed");
        assertEq(pool.reserve0(), r0, "reserves untouched");
    }

    function test_WithdrawProtocolFees_Guards() public {
        vm.prank(owner);
        vm.expectRevert(FeeManager.ZeroAddress.selector);
        pool.withdrawProtocolFees(address(0));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        pool.withdrawProtocolFees(alice);
    }

    function test_BurnAccumulated_Permissionless_DeadPathForVanillaToken() public {
        _seed(1000e18, 1000e18); // deposit burn creates earmarks on both tokens
        uint256 b0 = pool.burnToken0();
        uint256 b1 = pool.burnToken1();
        assertGt(b0, 0);
        uint256 r0 = pool.reserve0();
        address dead = pool.DEAD();

        vm.prank(bob); // anyone may crank
        pool.burnAccumulated();

        assertEq(tokenA.balanceOf(dead), b0, "vanilla token parked at dead address");
        assertEq(tokenB.balanceOf(dead), b1);
        assertEq(pool.burnToken0(), 0, "earmark zeroed");
        assertEq(pool.reserve0(), r0, "reserves untouched");
    }

    function test_BurnAccumulated_NothingToBurnReverts() public {
        vm.expectRevert(FeeManager.NothingToBurn.selector);
        pool.burnAccumulated();
    }

    function test_BurnAccumulated_TrueBurnPathForDeflationaryToken() public {
        // Fresh pool: DeflationaryToken (no tax controller) paired with a mock.
        DeflationaryToken mtk = new DeflationaryToken("Defl", "DFL", 1_000_000e18, alice, address(0));
        MockERC20 other = new MockERC20("Other", "OTH");
        StakedTokenLP lp2 = new StakedTokenLP("LP2", "LP2");

        AMMLiquidityPool pool2 = AMMLiquidityPool(
            address(
                new ERC1967Proxy(
                    address(new AMMLiquidityPool()),
                    abi.encodeCall(AMMLiquidityPool.initialize, (address(mtk), address(other), address(lp2), owner))
                )
            )
        );
        lp2.setMinter(address(pool2));

        other.mint(alice, 1_000e18);
        vm.startPrank(alice);
        mtk.approve(address(pool2), type(uint256).max);
        other.approve(address(pool2), type(uint256).max);
        pool2.deposit(1000e18, 1000e18, 0, block.timestamp + 1);
        vm.stopPrank();

        uint256 earmark = pool2.burnToken0();
        uint256 supplyBefore = mtk.totalSupply();

        pool2.burnAccumulated();

        assertEq(supplyBefore - mtk.totalSupply(), earmark, "true burn reduced totalSupply");
        assertEq(pool2.burnToken0(), 0);
    }
}
