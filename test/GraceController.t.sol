// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockERC20} from "./helpers/TestBase.sol";
import {AMMLiquidityPool} from "../contracts/AMMLiquidityPool.sol";
import {StakedTokenLP} from "../contracts/tokens/StakedTokenLP.sol";
import {DeflationaryToken} from "../contracts/tokens/DeflationaryToken.sol";
import {GraceWindowBurnController} from "../contracts/tokens/GraceWindowBurnController.sol";
import {EpochLib} from "../contracts/libraries/EpochLib.sol";

/// Integration tests for GraceWindowBurnController wired to the token (and,
/// for scope isolation, the pool). Every test maps to an item in
/// test/GraceController.CHECKLIST.md; the pure epoch math is already covered
/// by EpochLib.t.sol. Boundary tests pin exact seconds — this codebase has
/// been bitten once by strict-`>` vs `>=` ambiguity (Session 2 deadline bug).
contract GraceControllerTest is Test {
    uint256 constant SUPPLY = 1_000_000e18;
    uint256 constant BPS = 10_000;
    uint256 constant EPOCH = 8 hours; // 28_800
    uint256 constant SUB = 10 minutes; // 600

    // uint256 so `100e18 * BASE` promotes to 256-bit. As uint16/uint32 these
    // would compile the multiply in the literal's narrow mobile type and panic
    // by overflow — the exact footgun documented in Regression.t.sol. Cast
    // explicitly at the constructor call sites, which take the narrow types.
    uint256 constant ANCHOR = 1_750_000_000; // nonzero: exercises anchor math
    uint256 constant BASE = 200; // 2%
    uint256 constant GRACE = 100; // 1% — nonzero so "graced" != "exempt" in assertions
    uint256 constant MODULUS = 1; // window every epoch
    uint256 constant LEN = 6; // first hour

    GraceWindowBurnController ctrl;
    DeflationaryToken token;

    address bob = makeAddr("bob");
    address alice = makeAddr("alice");

    function setUp() public {
        // Mid-epoch, outside the window, well past the anchor.
        vm.warp(ANCHOR + 4 hours);
        ctrl = new GraceWindowBurnController(
            ANCHOR, uint16(BASE), uint16(GRACE), uint32(MODULUS), uint32(LEN)
        );
        token = new DeflationaryToken("Deflationary", "DFL", SUPPLY, address(this), address(ctrl));
    }

    // ─── helpers ─────────────────────────────────────────────────────────

    /// Transfer 100e18 to a fresh address at `ts` and return the burned amount.
    function _burnOnTransferAt(uint256 ts) internal returns (uint256 burned) {
        vm.warp(ts);
        address probe = makeAddr(string.concat("probe", vm.toString(ts)));
        uint256 supplyBefore = token.totalSupply();
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(probe, 100e18);
        burned = supplyBefore - token.totalSupply();
    }

    // ─── Rate semantics ──────────────────────────────────────────────────

    function test_InsideWindow_TransferBurnsAtGraceRate() public {
        assertEq(_burnOnTransferAt(ANCHOR + 10 minutes), (100e18 * GRACE) / BPS, "graced rate");
    }

    function test_OutsideWindow_TransferBurnsAtBaseRate() public {
        assertEq(_burnOnTransferAt(ANCHOR + 2 hours), (100e18 * BASE) / BPS, "base rate");
    }

    /// Half-open close boundary: a 6-subunit window is INACTIVE at exactly
    /// epoch start + 3,600 s. The strict-`>` vs `>=` bug class pin.
    function test_Boundary_WindowCloseSecond_PaysBase() public {
        assertEq(_burnOnTransferAt(ANCHOR + LEN * SUB), (100e18 * BASE) / BPS, "close second is base");
    }

    function test_Boundary_WindowCloseMinusOne_PaysGrace() public {
        assertEq(
            _burnOnTransferAt(ANCHOR + LEN * SUB - 1), (100e18 * GRACE) / BPS, "close-1 is graced"
        );
    }

    /// Window-open boundary: the anchor second itself is graced (epoch 0
    /// qualifies for any modulus, subunit 0 < LEN).
    function test_Boundary_AnchorSecond_PaysGrace() public {
        assertEq(_burnOnTransferAt(ANCHOR), (100e18 * GRACE) / BPS, "anchor second is graced");
    }

    /// Pre-anchor is never graced — base rate, both just-before and far-before.
    function test_PreAnchor_PaysBase() public {
        assertEq(_burnOnTransferAt(ANCHOR - 1), (100e18 * BASE) / BPS, "anchor-1 is base");
        assertEq(_burnOnTransferAt(ANCHOR - 30 days), (100e18 * BASE) / BPS, "far pre-anchor is base");
    }

    /// Later epochs' windows open at their own epoch start.
    function test_LaterEpoch_WindowOpensAtEpochStart() public {
        assertEq(_burnOnTransferAt(ANCHOR + 5 * EPOCH), (100e18 * GRACE) / BPS, "epoch 5 open second");
        assertEq(
            _burnOnTransferAt(ANCHOR + 5 * EPOCH + LEN * SUB),
            (100e18 * BASE) / BPS,
            "epoch 5 close second"
        );
    }

    /// Modulus > 1: only epochs with epoch % modulus == 0 get a window.
    function test_Modulus3_OnlyQualifyingEpochsGraced() public {
        GraceWindowBurnController c3 = new GraceWindowBurnController(ANCHOR, uint16(BASE), uint16(GRACE), 3, uint32(LEN));
        DeflationaryToken t3 =
            new DeflationaryToken("D3", "D3", SUPPLY, address(this), address(c3));

        uint256[2] memory graced = [uint256(0), 3]; // qualifying epochs
        uint256[2] memory ungraced = [uint256(1), 2];

        for (uint256 i = 0; i < 2; i++) {
            vm.warp(ANCHOR + graced[i] * EPOCH + 1);
            uint256 before = t3.totalSupply();
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            t3.transfer(bob, 100e18);
            assertEq(before - t3.totalSupply(), (100e18 * GRACE) / BPS, "qualifying epoch graced");

            vm.warp(ANCHOR + ungraced[i] * EPOCH + 1);
            before = t3.totalSupply();
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            t3.transfer(bob, 100e18);
            assertEq(before - t3.totalSupply(), (100e18 * BASE) / BPS, "non-qualifying epoch base");
        }
    }

    /// v5 parity config (3 / 48 / 0): the whole qualifying epoch is burn-free.
    function test_V5ParityConfig_WholeEpochFree() public {
        GraceWindowBurnController v5 = new GraceWindowBurnController(ANCHOR, uint16(BASE), 0, 3, 48);
        DeflationaryToken tv5 =
            new DeflationaryToken("V5", "V5", SUPPLY, address(this), address(v5));

        vm.warp(ANCHOR + EPOCH - 1); // last second of qualifying epoch 0
        uint256 before = tv5.totalSupply();
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        tv5.transfer(bob, 100e18);
        assertEq(tv5.totalSupply(), before, "entire qualifying epoch is burn-free");

        vm.warp(ANCHOR + EPOCH); // first second of epoch 1 (non-qualifying)
        before = tv5.totalSupply();
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        tv5.transfer(bob, 100e18);
        assertEq(before - tv5.totalSupply(), (100e18 * BASE) / BPS, "epoch 1 pays base");
    }

    /// Two-value fuzz: for any timestamp and any VALID parameter set, the
    /// controller's rate is exactly base or grace — never a third value —
    /// and agrees with its own graceActive() view.
    function testFuzz_TwoValueInvariant(
        uint256 ts,
        uint256 anchor_,
        uint16 base_,
        uint16 grace_,
        uint32 modulus_,
        uint32 len_
    ) public {
        base_ = uint16(bound(base_, 0, 1_000));
        grace_ = uint16(bound(grace_, 0, base_));
        modulus_ = uint32(bound(modulus_, 1, 1_000));
        len_ = uint32(bound(len_, 0, 48));
        anchor_ = bound(anchor_, 0, 4_000_000_000);
        ts = bound(ts, 0, 8_000_000_000);

        GraceWindowBurnController c =
            new GraceWindowBurnController(anchor_, base_, grace_, modulus_, len_);
        vm.warp(ts);

        uint256 bps = c.currentBurnBps();
        assertTrue(bps == base_ || bps == grace_, "rate is exactly base or grace");
        assertEq(bps, c.graceActive() ? grace_ : base_, "rate agrees with graceActive()");
        assertEq(
            c.getBurnAmount(alice, bob, 100e18), (100e18 * bps) / BPS, "burn amount uses that rate"
        );
    }

    // ─── Parameter governance (timelocked, atomic) ───────────────────────

    function test_Constructor_Guards() public {
        vm.expectRevert(
            abi.encodeWithSelector(GraceWindowBurnController.RateAboveCap.selector, 1_001, 1_000)
        );
        new GraceWindowBurnController(0, 1_001, 0, 1, 6);

        vm.expectRevert(
            abi.encodeWithSelector(GraceWindowBurnController.GraceAboveBase.selector, 201, 200)
        );
        new GraceWindowBurnController(0, 200, 201, 1, 6);

        vm.expectRevert(GraceWindowBurnController.ZeroModulus.selector);
        new GraceWindowBurnController(0, 200, 100, 0, 6);

        vm.expectRevert(
            abi.encodeWithSelector(
                GraceWindowBurnController.GraceLengthAboveEpoch.selector, 49, 48
            )
        );
        new GraceWindowBurnController(0, 200, 100, 1, 49);
    }

    function test_Schedule_RejectsZeroModulus() public {
        vm.expectRevert(GraceWindowBurnController.ZeroModulus.selector);
        ctrl.schedulePolicyUpdate(uint16(BASE), uint16(GRACE), 0, uint32(LEN));
    }

    function test_Schedule_RejectsGraceAboveBase() public {
        vm.expectRevert(
            abi.encodeWithSelector(GraceWindowBurnController.GraceAboveBase.selector, 201, 200)
        );
        ctrl.schedulePolicyUpdate(200, 201, uint32(MODULUS), uint32(LEN));
    }

    function test_Schedule_RejectsBaseAboveCap() public {
        vm.expectRevert(
            abi.encodeWithSelector(GraceWindowBurnController.RateAboveCap.selector, 1_001, 1_000)
        );
        ctrl.schedulePolicyUpdate(1_001, uint16(GRACE), uint32(MODULUS), uint32(LEN));
    }

    function test_Schedule_RejectsLengthAbove48() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                GraceWindowBurnController.GraceLengthAboveEpoch.selector, 49, 48
            )
        );
        ctrl.schedulePolicyUpdate(uint16(BASE), uint16(GRACE), uint32(MODULUS), 49);
    }

    function test_Schedule_OnlyOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        ctrl.schedulePolicyUpdate(uint16(BASE), uint16(GRACE), uint32(MODULUS), uint32(LEN));
    }

    function test_Execute_BeforeDelay_Reverts() public {
        ctrl.schedulePolicyUpdate(100, 0, 3, 12);
        uint64 unlock = uint64(block.timestamp + ctrl.POLICY_UPDATE_DELAY());
        vm.expectRevert(
            abi.encodeWithSelector(GraceWindowBurnController.TimelockActive.selector, unlock)
        );
        ctrl.executePolicyUpdate();
    }

    function test_Execute_AfterDelay_AppliesAtomically() public {
        ctrl.schedulePolicyUpdate(100, 0, 3, 12);
        vm.warp(block.timestamp + 1 days);
        ctrl.executePolicyUpdate();

        assertEq(ctrl.baseBurnBps(), 100, "base applied");
        assertEq(ctrl.graceBurnBps(), 0, "grace applied");
        assertEq(ctrl.epochModulus(), 3, "modulus applied");
        assertEq(ctrl.graceLengthSubunits(), 12, "length applied");

        // Pending cleared: a second execute has nothing to apply.
        vm.expectRevert(GraceWindowBurnController.NoPendingUpdate.selector);
        ctrl.executePolicyUpdate();
    }

    function test_Cancel_ClearsPending() public {
        ctrl.schedulePolicyUpdate(100, 0, 3, 12);
        ctrl.cancelPolicyUpdate();
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(GraceWindowBurnController.NoPendingUpdate.selector);
        ctrl.executePolicyUpdate();
        assertEq(ctrl.baseBurnBps(), BASE, "live policy untouched after cancel");
    }

    function test_ExecuteAndCancel_OnlyOwner_AndNoPendingReverts() public {
        vm.expectRevert(GraceWindowBurnController.NoPendingUpdate.selector);
        ctrl.cancelPolicyUpdate();

        ctrl.schedulePolicyUpdate(100, 0, 3, 12);
        // vm.prank affects only the NEXT call — no inline `new` between prank
        // and target (the test_Upgrade_PreservesAllState lesson).
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        ctrl.executePolicyUpdate();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        ctrl.cancelPolicyUpdate();
    }

    /// The anchor is immutable: it survives a policy update and the ABI has no
    /// setter for it (a clock change requires a controller swap).
    function test_Anchor_ImmutableAcrossPolicyUpdates() public {
        ctrl.schedulePolicyUpdate(100, 0, 3, 12);
        vm.warp(block.timestamp + 1 days);
        ctrl.executePolicyUpdate();
        assertEq(ctrl.anchor(), ANCHOR, "anchor unchanged by policy update");
    }

    // ─── Fail-open and gas ───────────────────────────────────────────────

    /// The rate lookup must fit comfortably inside the token's 100k-gas
    /// fail-open cap. Assert it succeeds with HALF that cap, cold storage,
    /// so a regression toward the ceiling fails loudly here first.
    function test_RateLookup_FitsWellInsideGasCap() public view {
        uint256 halfCap = 50_000; // token grants CONTROLLER_CALL_GAS = 100_000
        (bool ok, bytes memory ret) = address(ctrl).staticcall{gas: halfCap}(
            abi.encodeCall(ctrl.getBurnAmount, (alice, bob, 100e18))
        );
        assertTrue(ok, "lookup succeeds at half the token's gas cap");
        assertEq(abi.decode(ret, (uint256)), (100e18 * BASE) / BPS, "and returns the right amount");
    }

    /// Transfers keep working through the token's gas-capped try/catch with
    /// this controller specifically (the generic fail-open cases live in
    /// Tokens.t.sol with the Reverting/GasBomb controllers).
    function test_TokenTransfer_ThroughGasCappedHook_Succeeds() public {
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(bob, 100e18);
        assertEq(token.balanceOf(bob), 100e18 - (100e18 * BASE) / BPS, "capped hook applied rate");
    }

    // ─── Scope isolation (pool) ──────────────────────────────────────────

    /// Deploy token+pool with the grace controller, pool exempted (deploy
    /// script order). Returns the pool and the paired mock.
    function _deployPoolFixture()
        internal
        returns (AMMLiquidityPool pool, DeflationaryToken tkn, MockERC20 other)
    {
        GraceWindowBurnController c =
            new GraceWindowBurnController(
            ANCHOR, uint16(BASE), uint16(GRACE), uint32(MODULUS), uint32(LEN)
        );
        tkn = new DeflationaryToken("Defl", "DFL", SUPPLY, alice, address(c));
        other = new MockERC20("Other", "OTH");
        StakedTokenLP lp = new StakedTokenLP("LP", "LP");

        pool = AMMLiquidityPool(
            address(
                new ERC1967Proxy(
                    address(new AMMLiquidityPool()),
                    abi.encodeCall(
                        AMMLiquidityPool.initialize,
                        (address(tkn), address(other), address(lp), address(this))
                    )
                )
            )
        );
        lp.setMinter(address(pool));
        c.setExempt(address(pool), true);

        other.mint(alice, 1_000_000e18);
        vm.startPrank(alice);
        tkn.approve(address(pool), type(uint256).max);
        other.approve(address(pool), type(uint256).max);
        pool.deposit(10_000e18, 10_000e18, 0, block.timestamp + 1);
        vm.stopPrank();
    }

    /// Identical swaps from identical pool states, one inside a window and
    /// one outside, produce identical burn earmarks: the swap earmark is a
    /// pool mechanism the grace state cannot touch.
    function test_SwapEarmark_UnaffectedByGraceState() public {
        (AMMLiquidityPool p1, DeflationaryToken t1,) = _deployPoolFixture();
        (AMMLiquidityPool p2, DeflationaryToken t2,) = _deployPoolFixture();

        vm.warp(ANCHOR + 10 * EPOCH + 10 minutes); // inside a window
        vm.prank(alice);
        p1.swap(address(t1), 100e18, 0, block.timestamp + 1);
        uint256 earmarkInWindow = p1.burnToken0();

        vm.warp(ANCHOR + 10 * EPOCH + 4 hours); // outside any window
        vm.prank(alice);
        p2.swap(address(t2), 100e18, 0, block.timestamp + 1);
        uint256 earmarkOutside = p2.burnToken0();

        assertGt(earmarkInWindow, 0, "swap produced a burn earmark");
        assertEq(earmarkInWindow, earmarkOutside, "earmark identical in and out of window");
    }

    /// The pool's tax exemption holds regardless of window state: transfers
    /// touching the pool pay no transfer burn in or out of the window, so the
    /// pool receives exactly the stated amount.
    function test_PoolExemption_HoldsInAndOutOfWindow() public {
        (AMMLiquidityPool pool, DeflationaryToken tkn,) = _deployPoolFixture();
        uint256[2] memory times =
            [ANCHOR + 20 * EPOCH + 10 minutes, ANCHOR + 20 * EPOCH + 4 hours];

        for (uint256 i = 0; i < 2; i++) {
            vm.warp(times[i]);
            uint256 poolBefore = tkn.balanceOf(address(pool));
            uint256 supplyBefore = tkn.totalSupply();
            vm.prank(alice);
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            tkn.transfer(address(pool), 100e18);
            assertEq(
                tkn.balanceOf(address(pool)) - poolBefore, 100e18, "pool receives full amount"
            );
            assertEq(tkn.totalSupply(), supplyBefore, "no transfer burn on pool-involved transfer");
        }
    }

    // ─── View helpers ────────────────────────────────────────────────────

    /// currentBurnBps / graceActive / secondsUntilNextGrace agree with each
    /// other and with EpochLib at the boundary seconds.
    function test_ViewHelpers_AgreeAtBoundaries() public {
        uint256 epochStart = ANCHOR + 7 * EPOCH; // epoch 7, modulus 1: qualifies

        // Open second.
        vm.warp(epochStart);
        assertTrue(ctrl.graceActive(), "open: active");
        assertEq(ctrl.currentBurnBps(), GRACE, "open: graced rate");
        assertEq(ctrl.secondsUntilNextGrace(), 0, "open: countdown is 0");

        // Close - 1.
        vm.warp(epochStart + LEN * SUB - 1);
        assertTrue(ctrl.graceActive(), "close-1: active");
        assertEq(ctrl.currentBurnBps(), GRACE, "close-1: graced rate");
        assertEq(ctrl.secondsUntilNextGrace(), 0, "close-1: countdown is 0");

        // Close second: inactive; next window opens at the next epoch start.
        vm.warp(epochStart + LEN * SUB);
        assertFalse(ctrl.graceActive(), "close: inactive");
        assertEq(ctrl.currentBurnBps(), BASE, "close: base rate");
        assertEq(
            ctrl.secondsUntilNextGrace(), EPOCH - LEN * SUB, "close: countdown to next epoch start"
        );

        // Cross-check the countdown against the library at an arbitrary point.
        vm.warp(epochStart + 5 hours);
        assertEq(
            ctrl.secondsUntilNextGrace(),
            EpochLib.secondsUntilNextGrace(block.timestamp, ANCHOR, MODULUS, LEN),
            "controller countdown matches EpochLib"
        );
        // Warping by it lands inside an active window.
        vm.warp(block.timestamp + ctrl.secondsUntilNextGrace());
        assertTrue(ctrl.graceActive(), "warp-by-countdown lands in a window");
    }

    /// Pre-anchor: not active, base rate, countdown reaches to the anchor.
    function test_ViewHelpers_PreAnchor() public {
        vm.warp(ANCHOR - 12 hours);
        assertFalse(ctrl.graceActive(), "pre-anchor never active");
        assertEq(ctrl.currentBurnBps(), BASE, "pre-anchor pays base");
        assertEq(ctrl.secondsUntilNextGrace(), 12 hours, "countdown reaches the anchor");
    }

    // ─── Supply monotonicity across grace states ─────────────────────────

    /// Stateful fuzz: interleave transfers at fuzzed timestamps (in and out
    /// of windows, pre- and post-anchor); total supply never increases.
    /// (The full-pool invariant-suite integration is tracked separately in
    /// the CHECKLIST; this pins the token-side property.)
    function testFuzz_SupplyNeverIncreases_AcrossGraceStates(uint256[8] memory tsSeeds) public {
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(alice, 500_000e18);
        uint256 lastSupply = token.totalSupply();
        uint256 t = ANCHOR - 2 * EPOCH; // start pre-anchor; move only forward

        for (uint256 i = 0; i < tsSeeds.length; i++) {
            t += bound(tsSeeds[i], 1, 2 * EPOCH);
            vm.warp(t);
            address from = i % 2 == 0 ? address(this) : alice;
            vm.prank(from);
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            token.transfer(bob, 1_000e18);
            assertLe(token.totalSupply(), lastSupply, "supply never increases");
            lastSupply = token.totalSupply();
        }
    }
}
