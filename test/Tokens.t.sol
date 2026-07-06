// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockERC20, MaxTaxController, RevertingController, GasBombController} from "./helpers/TestBase.sol";
import {DeflationaryToken} from "../contracts/tokens/DeflationaryToken.sol";
import {StakedTokenLP} from "../contracts/tokens/StakedTokenLP.sol";
import {FlatRateBurnController} from "../contracts/tokens/FlatRateBurnController.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// Unit + fuzz tests for both tokens: tax cap, fail-open hook, untaxed burns,
/// timelocked controller, two-step ownership, permit, one-shot minter.
contract DeflationaryTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000e18;
    address bob = makeAddr("bob");

    function _newToken(address controller) internal returns (DeflationaryToken t) {
        t = new DeflationaryToken("Deflationary", "DFL", SUPPLY, address(this), controller);
    }

    // ─── Tax behavior ───────────────────────────────────────────────────

    function test_NoController_NoTax() public {
        DeflationaryToken t = _newToken(address(0));
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        t.transfer(bob, 100e18);
        assertEq(t.balanceOf(bob), 100e18);
        assertEq(t.totalSupply(), SUPPLY);
    }

    function test_FlatRate_TaxIsTrueBurn() public {
        FlatRateBurnController c = new FlatRateBurnController(200); // 2%
        DeflationaryToken t = _newToken(address(c));

        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        t.transfer(bob, 100e18);

        assertEq(t.balanceOf(bob), 98e18, "recipient gets amount minus tax");
        assertEq(t.totalSupply(), SUPPLY - 2e18, "tax reduces totalSupply (true burn)");
        assertEq(t.totalBurned(), 2e18, "derived counter matches");
    }

    function test_Exemption_ZeroTax() public {
        FlatRateBurnController c = new FlatRateBurnController(200);
        c.setExempt(address(this), true);
        DeflationaryToken t = _newToken(address(c));

        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        t.transfer(bob, 100e18);
        assertEq(t.balanceOf(bob), 100e18, "exempt sender pays no tax");
    }

    function test_MaliciousController_ClampedToHardCap() public {
        DeflationaryToken t = _newToken(address(new MaxTaxController()));

        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        t.transfer(bob, 100e18);

        uint256 maxTax = (100e18 * t.MAX_BURN_BPS()) / t.BPS(); // 10e18
        assertEq(t.balanceOf(bob), 100e18 - maxTax, "tax clamped to 10% regardless of controller");
    }

    function test_RevertingController_FailsOpen() public {
        DeflationaryToken t = _newToken(address(new RevertingController()));
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        t.transfer(bob, 100e18);
        assertEq(t.balanceOf(bob), 100e18, "broken controller cannot freeze or tax transfers");
    }

    function test_GasBombController_ContainedByGasCap() public {
        DeflationaryToken t = _newToken(address(new GasBombController()));
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        t.transfer(bob, 100e18);
        assertEq(t.balanceOf(bob), 100e18, "gas-hungry controller contained; zero tax");
    }

    function test_VoluntaryBurn_NeverTaxed() public {
        DeflationaryToken t = _newToken(address(new MaxTaxController()));
        uint256 before = t.totalSupply();

        t.burn(50e18); // ERC20Burnable path: to == address(0), hook skipped

        assertEq(before - t.totalSupply(), 50e18, "burn destroys exactly the stated amount");
        assertEq(t.totalBurned(), 50e18);
    }

    function testFuzz_TaxNeverExceedsHardCap(uint256 amount) public {
        amount = bound(amount, 1, SUPPLY);
        DeflationaryToken t = _newToken(address(new MaxTaxController()));

        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        t.transfer(bob, amount);

        uint256 maxTax = (amount * t.MAX_BURN_BPS()) / t.BPS();
        assertGe(t.balanceOf(bob), amount - maxTax, "received at least 90%");
        assertEq(t.balanceOf(bob), amount - maxTax, "clamp is exact");
    }

    // ─── Constructor guards ─────────────────────────────────────────────

    function test_Constructor_Reverts() public {
        vm.expectRevert(DeflationaryToken.ZeroAddress.selector);
        new DeflationaryToken("D", "D", SUPPLY, address(0), address(0));

        vm.expectRevert(DeflationaryToken.ZeroSupply.selector);
        new DeflationaryToken("D", "D", 0, address(this), address(0));

        vm.expectRevert(DeflationaryToken.ControllerNotContract.selector);
        new DeflationaryToken("D", "D", SUPPLY, address(this), makeAddr("eoa"));
    }

    // ─── Timelocked controller governance ──────────────────────────────

    function test_ControllerUpdate_Lifecycle() public {
        DeflationaryToken t = _newToken(address(0));
        FlatRateBurnController c = new FlatRateBurnController(200);
        uint64 expectedUnlock = uint64(block.timestamp + t.CONTROLLER_UPDATE_DELAY());

        vm.expectRevert(DeflationaryToken.ControllerNotContract.selector);
        t.scheduleControllerUpdate(makeAddr("eoa"));

        t.scheduleControllerUpdate(address(c));

        vm.expectRevert(
            abi.encodeWithSelector(DeflationaryToken.TimelockActive.selector, expectedUnlock)
        );
        t.executeControllerUpdate();

        vm.warp(expectedUnlock);
        t.executeControllerUpdate();
        assertEq(address(t.burnController()), address(c), "controller live after timelock");

        // scheduling address(0) is the kill switch
        t.scheduleControllerUpdate(address(0));
        vm.warp(block.timestamp + t.CONTROLLER_UPDATE_DELAY());
        t.executeControllerUpdate();
        assertEq(address(t.burnController()), address(0), "tax disabled");
    }

    function test_ControllerUpdate_CancelClearsPending() public {
        DeflationaryToken t = _newToken(address(0));
        t.scheduleControllerUpdate(address(new FlatRateBurnController(100)));
        t.cancelControllerUpdate();

        vm.expectRevert(DeflationaryToken.NoPendingUpdate.selector);
        t.executeControllerUpdate();
    }

    // ─── Two-step ownership ─────────────────────────────────────────────

    function test_TwoStepOwnership() public {
        DeflationaryToken t = _newToken(address(0));

        t.transferOwnership(bob);
        assertEq(t.owner(), address(this), "transfer alone does not change owner");
        assertEq(t.pendingOwner(), bob);

        vm.prank(bob);
        t.acceptOwnership();
        assertEq(t.owner(), bob, "owner changes only on accept");
    }

    // ─── Permit ─────────────────────────────────────────────────────────

    function test_Permit_ApprovesWithoutTransaction() public {
        DeflationaryToken t = _newToken(address(0));
        (address user, uint256 pk) = makeAddrAndKey("permitUser");
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        t.transfer(user, 100e18);

        uint256 deadline = block.timestamp + 1 days;
        bytes32 typehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash =
            keccak256(abi.encode(typehash, user, bob, 60e18, t.nonces(user), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", t.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        t.permit(user, bob, 60e18, deadline, v, r, s); // callable by anyone
        assertEq(t.allowance(user, bob), 60e18);

        vm.prank(bob);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        t.transferFrom(user, bob, 60e18);
        assertEq(t.balanceOf(bob), 60e18);
    }
}

contract StakedTokenLPTest is Test {
    StakedTokenLP lpt;
    address bob = makeAddr("bob");

    function setUp() public {
        lpt = new StakedTokenLP("Pool LP", "PLP");
    }

    function test_SetMinter_OneShot() public {
        address minter = address(new MockERC20("codeful", "C")); // any contract works
        lpt.setMinter(minter);
        assertEq(lpt.minter(), minter);

        vm.expectRevert(StakedTokenLP.MinterAlreadySet.selector);
        lpt.setMinter(address(this));
    }

    function test_SetMinter_Guards() public {
        vm.expectRevert(StakedTokenLP.ZeroAddress.selector);
        lpt.setMinter(address(0));

        vm.expectRevert(StakedTokenLP.NotAContract.selector);
        lpt.setMinter(makeAddr("eoa"));
    }

    function test_OnlyMinterMintsAndBurns() public {
        address minter = address(new MockERC20("codeful", "C"));
        lpt.setMinter(minter);

        vm.expectRevert(StakedTokenLP.NotMinter.selector);
        lpt.mint(bob, 1e18);

        vm.startPrank(minter);
        lpt.mint(bob, 1e18);
        lpt.burn(bob, 0.4e18);
        vm.stopPrank();
        assertEq(lpt.balanceOf(bob), 0.6e18);
    }
}
