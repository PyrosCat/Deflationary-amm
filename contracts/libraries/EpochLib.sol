// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  EpochLib
/// @notice Pure time-bucketing math: 8-hour epochs, each divided into 48
///         ten-minute subunits, plus grace-window predicates parameterized by
///         an anchor timestamp, epoch modulus, and window length.
/// @dev    VERIFIED against the recovered v5 `EpochUtils.sol`
///         (archived verbatim at `archive/v5/EpochUtils.sol`):
///           - 8-hour epoch and 10-minute subunit constants CONFIRMED (the
///             v5 comment saying "12-hour epoch" is wrong; the constant was
///             authoritative). Constant names below match v5's.
///           - v5 was NOT unix-anchored: it took a constructor `epochStart`.
///             This library therefore takes an `anchor` parameter everywhere;
///             `anchor == 0` gives unix anchoring (windows open at 00:00,
///             08:00, 16:00 UTC), any other value reproduces v5 semantics.
///           - v5 clamped pre-anchor queries to zero. `epochOf`/`subunitOf`
///             keep that clamp for parity; the grace predicates additionally
///             define pre-anchor time as NOT in a window (the first window
///             opens exactly at the anchor).
///
///         The anchor defines the clock itself, not the policy: consuming
///         controllers should hold it as a constructor immutable (v5 parity),
///         changed only by swapping the controller — never as a live setter,
///         which would silently re-bucket every epoch.
///
///         Deployed as an internal library (compiled into the consuming
///         controller). All functions are pure; there is no state and no
///         external call surface.
library EpochLib {
    /// @notice Length of one epoch. 8 hours = 28,800 seconds.
    uint256 internal constant EPOCH_DURATION = 8 hours;

    /// @notice Length of one subunit. 10 minutes = 600 seconds.
    uint256 internal constant SUBUNIT_DURATION = 10 minutes;

    /// @notice Subunits per epoch. 28,800 / 600 = 48.
    uint256 internal constant SUBUNITS_PER_EPOCH = EPOCH_DURATION / SUBUNIT_DURATION;

    /// @notice Epoch number containing `timestamp`, counted from `anchor`.
    ///         Epoch 0 begins at `anchor`. Pre-anchor timestamps clamp to
    ///         epoch 0 (v5 parity).
    function epochOf(uint256 timestamp, uint256 anchor) internal pure returns (uint256) {
        if (timestamp < anchor) {
            return 0;
        }
        return (timestamp - anchor) / EPOCH_DURATION;
    }

    /// @notice Subunit index of `timestamp` within its epoch. Range [0, 47].
    ///         Pre-anchor timestamps clamp to subunit 0 (v5 parity).
    function subunitOf(uint256 timestamp, uint256 anchor) internal pure returns (uint256) {
        if (timestamp < anchor) {
            return 0;
        }
        return ((timestamp - anchor) % EPOCH_DURATION) / SUBUNIT_DURATION;
    }

    /// @notice Whether `timestamp` falls inside a grace window.
    /// @dev    Half-open semantics: the window covers subunits
    ///         [0, graceLengthSubunits) of each qualifying epoch. A window of
    ///         length 6 is active for exactly the first 3,600 seconds of the
    ///         epoch and INACTIVE at second 3,600. `graceLengthSubunits == 0`
    ///         disables the window entirely; `48` graces the whole epoch.
    ///
    ///         Qualifying epochs satisfy `epoch % epochModulus == 0`;
    ///         `epochModulus == 1` makes every epoch qualify.
    ///
    ///         Pre-anchor time is never inside a window — the first window
    ///         opens exactly at `anchor` (note this deliberately diverges
    ///         from the raw clamp in `epochOf`/`subunitOf`, which would
    ///         otherwise read the entire pre-anchor period as epoch 0,
    ///         subunit 0 and grace it).
    ///
    ///         `epochModulus` MUST be >= 1. This library does not guard the
    ///         zero case (it panics by division); the guard belongs in the
    ///         consuming controller's parameter setter.
    function graceActive(
        uint256 timestamp,
        uint256 anchor,
        uint256 epochModulus,
        uint256 graceLengthSubunits
    ) internal pure returns (bool) {
        if (timestamp < anchor) {
            return false;
        }
        if (epochOf(timestamp, anchor) % epochModulus != 0) {
            return false;
        }
        return subunitOf(timestamp, anchor) < graceLengthSubunits;
    }

    /// @notice Seconds from `timestamp` until the next grace window opens.
    ///         Returns 0 if a window is active at `timestamp`. Pre-anchor,
    ///         returns the seconds until the anchor (where the first window
    ///         opens). Intended as a frontend/countdown helper surfaced by
    ///         the controller.
    /// @dev    If `graceLengthSubunits == 0` (feature disabled) the return
    ///         value is the time until the next qualifying epoch boundary,
    ///         at which no window will actually open — callers should treat
    ///         the result as meaningless when the feature is disabled.
    function secondsUntilNextGrace(
        uint256 timestamp,
        uint256 anchor,
        uint256 epochModulus,
        uint256 graceLengthSubunits
    ) internal pure returns (uint256) {
        if (graceActive(timestamp, anchor, epochModulus, graceLengthSubunits)) {
            return 0;
        }
        if (timestamp < anchor) {
            return anchor - timestamp;
        }
        uint256 epoch = epochOf(timestamp, anchor);
        uint256 r = epoch % epochModulus;
        // If the current epoch qualifies (r == 0) we are past its window, so
        // the next opening is `epochModulus` epochs ahead; otherwise round
        // the epoch number up to the next multiple of `epochModulus`.
        uint256 nextQualifying = r == 0 ? epoch + epochModulus : epoch + (epochModulus - r);
        return anchor + nextQualifying * EPOCH_DURATION - timestamp;
    }
}
