// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EpochLib} from "../contracts/libraries/EpochLib.sol";

/// @notice Unit + fuzz tests for EpochLib. These run standalone against the
///         library and require no deployed contracts.
///
///         Boundary tests are deliberately paranoid: this codebase has been
///         bitten once already by strict-`>` vs `>=` ambiguity (the swap
///         deadline test in Session 2). The grace window uses half-open
///         semantics — active while subunit < graceLengthSubunits — and the
///         tests below pin the exact open and close seconds, plus the anchor
///         boundary (verified against the recovered v5 `EpochUtils.sol`,
///         archived at `archive/v5/EpochUtils.sol`).
contract EpochLibTest is Test {
    uint256 internal constant EPOCH = 8 hours; // 28_800
    uint256 internal constant SUB = 10 minutes; // 600
    uint256 internal constant ANCHOR = 1_750_000_000; // arbitrary nonzero anchor

    // ---------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------

    function test_Constants() public pure {
        assertEq(EpochLib.EPOCH_DURATION, 28_800, "epoch duration");
        assertEq(EpochLib.SUBUNIT_DURATION, 600, "subunit duration");
        assertEq(EpochLib.SUBUNITS_PER_EPOCH, 48, "subunits per epoch");
    }

    // ---------------------------------------------------------------
    // Epoch counting — unix anchor (anchor = 0)
    // ---------------------------------------------------------------

    function test_EpochOf_UnixAnchor() public pure {
        assertEq(EpochLib.epochOf(0, 0), 0, "unix 0 is epoch 0");
        assertEq(EpochLib.epochOf(EPOCH - 1, 0), 0, "last second of epoch 0");
        assertEq(EpochLib.epochOf(EPOCH, 0), 1, "first second of epoch 1");
        assertEq(EpochLib.epochOf(2 * EPOCH, 0), 2, "first second of epoch 2");
    }

    // ---------------------------------------------------------------
    // Epoch counting — custom anchor, with the v5 pre-anchor clamp
    // ---------------------------------------------------------------

    function test_EpochOf_CustomAnchor_AndV5Clamp() public pure {
        assertEq(EpochLib.epochOf(ANCHOR - 1, ANCHOR), 0, "pre-anchor clamps to epoch 0 (v5 parity)");
        assertEq(EpochLib.epochOf(0, ANCHOR), 0, "far pre-anchor clamps to epoch 0");
        assertEq(EpochLib.epochOf(ANCHOR, ANCHOR), 0, "epoch 0 begins at the anchor");
        assertEq(EpochLib.epochOf(ANCHOR + EPOCH - 1, ANCHOR), 0, "last second of epoch 0");
        assertEq(EpochLib.epochOf(ANCHOR + EPOCH, ANCHOR), 1, "first second of epoch 1");
    }

    // ---------------------------------------------------------------
    // Subunit boundaries
    // ---------------------------------------------------------------

    function test_SubunitOf_Boundaries_UnixAnchor() public pure {
        assertEq(EpochLib.subunitOf(0, 0), 0, "epoch start is subunit 0");
        assertEq(EpochLib.subunitOf(SUB - 1, 0), 0, "last second of subunit 0");
        assertEq(EpochLib.subunitOf(SUB, 0), 1, "first second of subunit 1");
        assertEq(EpochLib.subunitOf(6 * SUB, 0), 6, "one hour in is subunit 6");
        assertEq(EpochLib.subunitOf(EPOCH - 1, 0), 47, "last second of epoch is subunit 47");
        assertEq(EpochLib.subunitOf(EPOCH, 0), 0, "next epoch resets to subunit 0");
    }

    function test_SubunitOf_CustomAnchor_AndV5Clamp() public pure {
        assertEq(EpochLib.subunitOf(ANCHOR - 1, ANCHOR), 0, "pre-anchor clamps to subunit 0 (v5 parity)");
        assertEq(EpochLib.subunitOf(ANCHOR, ANCHOR), 0, "anchor second is subunit 0");
        assertEq(EpochLib.subunitOf(ANCHOR + SUB, ANCHOR), 1, "first second of subunit 1");
        assertEq(EpochLib.subunitOf(ANCHOR + EPOCH - 1, ANCHOR), 47, "last second of epoch");
    }

    // ---------------------------------------------------------------
    // Grace window: modulus 1, one-hour window (the recommended default)
    // ---------------------------------------------------------------

    function test_Grace_Modulus1_FirstHour_HalfOpenBoundaries() public pure {
        uint256 m = 1;
        uint256 len = 6; // 6 subunits = 3,600 s

        // Epoch 0 (unix anchor)
        assertTrue(EpochLib.graceActive(0, 0, m, len), "open at epoch second 0");
        assertTrue(EpochLib.graceActive(3_599, 0, m, len), "active at close - 1s");
        assertFalse(EpochLib.graceActive(3_600, 0, m, len), "INACTIVE at exact close second");
        assertFalse(EpochLib.graceActive(EPOCH - 1, 0, m, len), "inactive at epoch end");

        // Epoch 1 (modulus 1: every epoch qualifies)
        assertTrue(EpochLib.graceActive(EPOCH, 0, m, len), "reopens at next epoch start");
        assertTrue(EpochLib.graceActive(EPOCH + 3_599, 0, m, len), "active at close - 1s (epoch 1)");
        assertFalse(EpochLib.graceActive(EPOCH + 3_600, 0, m, len), "inactive at close (epoch 1)");
    }

    // ---------------------------------------------------------------
    // Grace window: anchored — pre-anchor is NEVER graced, first window
    // opens exactly at the anchor
    // ---------------------------------------------------------------

    function test_Grace_Anchored_PreAnchorNeverActive() public pure {
        uint256 m = 1;
        uint256 len = 6;

        // Pre-anchor: raw getters clamp to (epoch 0, subunit 0), which would
        // naively read as "in the window" — the predicate must say NO.
        assertFalse(EpochLib.graceActive(ANCHOR - 1, ANCHOR, m, len), "1s before anchor: not graced");
        assertFalse(EpochLib.graceActive(0, ANCHOR, m, len), "far before anchor: not graced");

        // The first window opens exactly at the anchor second.
        assertTrue(EpochLib.graceActive(ANCHOR, ANCHOR, m, len), "opens at the anchor second");
        assertTrue(EpochLib.graceActive(ANCHOR + 3_599, ANCHOR, m, len), "active at close - 1s");
        assertFalse(EpochLib.graceActive(ANCHOR + 3_600, ANCHOR, m, len), "inactive at exact close");
    }

    // ---------------------------------------------------------------
    // Grace window: modulus 3, full epoch — reproduces v5 cadence exactly
    // ---------------------------------------------------------------

    function test_Grace_Modulus3_FullEpoch_ReproducesV5() public pure {
        uint256 m = 3;
        uint256 len = 48; // whole epoch graced

        // Epoch 0 qualifies (0 % 3 == 0): free for the entire epoch.
        assertTrue(EpochLib.graceActive(ANCHOR, ANCHOR, m, len), "epoch 0 start");
        assertTrue(EpochLib.graceActive(ANCHOR + EPOCH - 1, ANCHOR, m, len), "epoch 0 last second");

        // Epochs 1 and 2 do not qualify.
        assertFalse(EpochLib.graceActive(ANCHOR + EPOCH, ANCHOR, m, len), "epoch 1 start");
        assertFalse(EpochLib.graceActive(ANCHOR + 2 * EPOCH + 123, ANCHOR, m, len), "epoch 2 interior");
        assertFalse(EpochLib.graceActive(ANCHOR + 3 * EPOCH - 1, ANCHOR, m, len), "epoch 2 last second");

        // Epoch 3 qualifies again.
        assertTrue(EpochLib.graceActive(ANCHOR + 3 * EPOCH, ANCHOR, m, len), "epoch 3 start");
        assertTrue(EpochLib.graceActive(ANCHOR + 4 * EPOCH - 1, ANCHOR, m, len), "epoch 3 last second");

        // Epoch 4 does not.
        assertFalse(EpochLib.graceActive(ANCHOR + 4 * EPOCH, ANCHOR, m, len), "epoch 4 start");
    }

    // ---------------------------------------------------------------
    // Zero-length window disables the feature
    // ---------------------------------------------------------------

    function test_Grace_ZeroLength_NeverActive() public pure {
        assertFalse(EpochLib.graceActive(0, 0, 1, 0), "not active at unix epoch start");
        assertFalse(EpochLib.graceActive(EPOCH, 0, 1, 0), "not active at any epoch start");
        assertFalse(EpochLib.graceActive(ANCHOR, ANCHOR, 1, 0), "not active at the anchor either");
        assertFalse(EpochLib.graceActive(12_345, 0, 1, 0), "not active mid-epoch");
    }

    // ---------------------------------------------------------------
    // secondsUntilNextGrace
    // ---------------------------------------------------------------

    function test_SecondsUntilNextGrace_Deterministic() public pure {
        // Active now -> 0.
        assertEq(EpochLib.secondsUntilNextGrace(0, 0, 1, 6), 0, "active at t=0");
        assertEq(EpochLib.secondsUntilNextGrace(3_599, 0, 1, 6), 0, "active at close - 1s");

        // Just closed, modulus 1: wait until the next epoch start.
        assertEq(
            EpochLib.secondsUntilNextGrace(3_600, 0, 1, 6),
            EPOCH - 3_600,
            "from exact close second to next epoch start"
        );

        // Modulus 3, full-epoch window, sitting at epoch 1 start: next
        // qualifying epoch is 3.
        assertEq(
            EpochLib.secondsUntilNextGrace(ANCHOR + EPOCH, ANCHOR, 3, 48),
            2 * EPOCH,
            "epoch 1 start to epoch 3 start"
        );

        // Same schedule, mid-epoch-1.
        assertEq(
            EpochLib.secondsUntilNextGrace(ANCHOR + EPOCH + 1_200, ANCHOR, 3, 48),
            2 * EPOCH - 1_200,
            "mid epoch 1 to epoch 3 start"
        );

        // Pre-anchor: counts down to the anchor, where the first window opens.
        assertEq(
            EpochLib.secondsUntilNextGrace(ANCHOR - 500, ANCHOR, 1, 6),
            500,
            "pre-anchor counts down to the anchor"
        );
    }

    // ---------------------------------------------------------------
    // Fuzz properties
    // ---------------------------------------------------------------

    /// Subunit is always within [0, 47] for any timestamp and anchor.
    function testFuzz_Subunit_AlwaysInRange(uint256 timestamp, uint256 anchor) public pure {
        assertLt(EpochLib.subunitOf(timestamp, anchor), 48, "subunit out of range");
    }

    /// Epoch number never decreases as time moves forward (fixed anchor).
    function testFuzz_Epoch_Monotonic(uint64 timestamp, uint32 delta, uint64 anchor) public pure {
        assertGe(
            EpochLib.epochOf(uint256(timestamp) + delta, anchor),
            EpochLib.epochOf(timestamp, anchor),
            "epoch went backwards"
        );
    }

    /// The half-open close boundary holds for every window length under
    /// modulus 1 and any anchor: active at close - 1s, inactive at the exact
    /// close second (unless the window covers the whole epoch, in which case
    /// the "close" second is the next epoch's opening second under modulus 1
    /// and is active again).
    function testFuzz_WindowCloseBoundary(uint64 anchor, uint32 epochSeed, uint8 lenSeed) public pure {
        uint256 len = (uint256(lenSeed) % 48) + 1; // 1..48
        uint256 epochStart = uint256(anchor) + uint256(epochSeed) * EPOCH; // every epoch qualifies at m=1
        uint256 closeAt = epochStart + len * SUB;

        assertTrue(EpochLib.graceActive(closeAt - 1, anchor, 1, len), "active at close - 1s");
        if (len < 48) {
            assertFalse(EpochLib.graceActive(closeAt, anchor, 1, len), "inactive at exact close");
        } else {
            assertTrue(
                EpochLib.graceActive(closeAt, anchor, 1, len),
                "len 48: close second is next epoch's open"
            );
        }
    }

    /// Warping forward by secondsUntilNextGrace always lands inside an
    /// active window (any anchor, modulus 1..10, length 1..48) — including
    /// from pre-anchor timestamps.
    function testFuzz_SecondsUntilNextGrace_LandsInWindow(
        uint64 timestamp,
        uint64 anchor,
        uint8 modSeed,
        uint8 lenSeed
    ) public pure {
        uint256 m = (uint256(modSeed) % 10) + 1; // 1..10
        uint256 len = (uint256(lenSeed) % 48) + 1; // 1..48
        uint256 wait = EpochLib.secondsUntilNextGrace(timestamp, anchor, m, len);
        assertTrue(
            EpochLib.graceActive(uint256(timestamp) + wait, anchor, m, len),
            "did not land in an active window"
        );
    }

    /// Pre-anchor timestamps are never graced, for any parameters.
    function testFuzz_PreAnchor_NeverGraced(uint64 timestamp, uint64 anchor, uint8 modSeed, uint8 lenSeed) public pure {
        vm.assume(timestamp < anchor);
        uint256 m = (uint256(modSeed) % 10) + 1;
        uint256 len = uint256(lenSeed) % 49; // 0..48
        assertFalse(EpochLib.graceActive(timestamp, anchor, m, len), "pre-anchor graced");
    }
}
