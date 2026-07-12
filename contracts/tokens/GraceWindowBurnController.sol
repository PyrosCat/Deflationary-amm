// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IBurnController.sol";
import "../libraries/EpochLib.sol";

/// @notice IBurnController with an epoch grace window: transfers pay
///         `baseBurnBps` normally and `graceBurnBps` while a window is open.
///         Windows open for the first `graceLengthSubunits` ten-minute
///         subunits of every epoch whose number satisfies
///         `epoch % epochModulus == 0`, on the clock defined by the
///         immutable `anchor` (0 = unix anchoring: 00:00 / 08:00 / 16:00 UTC).
///         Design record: docs/design/DESIGN-GRACE-WINDOW.md (normative section 4).
///
/// @dev    Policy vs. clock, per the design doc:
///         - The four POLICY values (`baseBurnBps`, `graceBurnBps`,
///           `epochModulus`, `graceLengthSubunits`) change only through the
///           1-day timelock below, and only atomically as one set. Atomic
///           because `graceBurnBps <= baseBurnBps` couples the rates: two
///           independent setters would force an ordering dance (lower grace
///           before lowering base) and leave a window where a half-applied
///           schedule is live. Same precedent as FeeController's split
///           update. This also supersedes FlatRateBurnController's instant
///           `setBurnRate` — this is the "hardened" controller its header
///           anticipated; the base rate here is timelocked like the rest.
///         - The CLOCK (`anchor`) is a constructor immutable with NO setter.
///           Changing the anchor silently re-buckets every epoch and moves
///           every window; a clock change requires deploying a new controller
///           and swapping it behind the token's own timelock.
///
///         Fail-open contract (token side): `getBurnAmount` is called with a
///         100k gas cap inside try/catch. The lookup here is three warm-path
///         SLOADs (two exemption slots + one packed parameter slot) plus pure
///         EpochLib math — comfortably inside the cap. It cannot revert:
///         `epochModulus >= 1` is guard-enforced at construction and at
///         execute, so EpochLib's modulus division never panics, and the
///         bps product is overflow-safe for any real token amount (same
///         form as FlatRateBurnController; a theoretical overflow on an
///         absurd `amount` is caught by the token's fail-open catch anyway).
///
///         `graceLengthSubunits` above 48 is REJECTED, not normalized
///         (checklist decision): silently clamping owner input hides typos;
///         48 already graces the whole epoch, so nothing is lost.
///
///         Exemptions are instant (FlatRateBurnController parity): they are
///         operational wiring — the deploy script exempts the pool so swaps
///         never pay the transfer burn — not economic policy.
contract GraceWindowBurnController is Ownable, IBurnController {
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_RATE_BPS = 1_000; // mirrors the token's ceiling
    uint256 public constant POLICY_UPDATE_DELAY = 1 days;
    uint256 public constant MAX_GRACE_LENGTH = EpochLib.SUBUNITS_PER_EPOCH; // 48

    /// @notice Timestamp at which epoch 0 begins. 0 = unix anchoring.
    ///         Immutable by design — see the header. There is no setter.
    uint256 public immutable anchor;

    // The four policy values share one storage slot so the transfer hot path
    // pays a single SLOAD for all of them.
    uint16 public baseBurnBps;
    uint16 public graceBurnBps;
    uint32 public epochModulus;
    uint32 public graceLengthSubunits;

    struct PendingPolicy {
        uint16 baseBurnBps;
        uint16 graceBurnBps;
        uint32 epochModulus;
        uint32 graceLengthSubunits;
        uint64 executeAfter;
        bool exists;
    }

    PendingPolicy public pendingPolicy;

    mapping(address => bool) public exempt;

    error RateAboveCap(uint256 requested, uint256 cap);
    error GraceAboveBase(uint256 graceBps, uint256 baseBps);
    error ZeroModulus();
    error GraceLengthAboveEpoch(uint256 requested, uint256 cap);
    error NoPendingUpdate();
    error TimelockActive(uint64 executeAfter);

    event PolicyUpdateScheduled(
        uint16 baseBurnBps,
        uint16 graceBurnBps,
        uint32 epochModulus,
        uint32 graceLengthSubunits,
        uint64 executeAfter
    );
    event PolicyUpdateCancelled();
    event PolicyUpdated(
        uint16 baseBurnBps, uint16 graceBurnBps, uint32 epochModulus, uint32 graceLengthSubunits
    );
    event ExemptionSet(address indexed account, bool isExempt);

    constructor(
        uint256 anchor_,
        uint16 baseBurnBps_,
        uint16 graceBurnBps_,
        uint32 epochModulus_,
        uint32 graceLengthSubunits_
    ) Ownable(msg.sender) {
        anchor = anchor_;
        _validate(baseBurnBps_, graceBurnBps_, epochModulus_, graceLengthSubunits_);
        _apply(baseBurnBps_, graceBurnBps_, epochModulus_, graceLengthSubunits_);
    }

    // ─── Timelocked policy governance ───────────────────────────────────

    function schedulePolicyUpdate(
        uint16 baseBurnBps_,
        uint16 graceBurnBps_,
        uint32 epochModulus_,
        uint32 graceLengthSubunits_
    ) external onlyOwner {
        _validate(baseBurnBps_, graceBurnBps_, epochModulus_, graceLengthSubunits_);
        // casting to 'uint64' is safe: block.timestamp + 1 day < 2**64 until year ~584e9
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 executeAfter = uint64(block.timestamp + POLICY_UPDATE_DELAY);
        pendingPolicy = PendingPolicy(
            baseBurnBps_, graceBurnBps_, epochModulus_, graceLengthSubunits_, executeAfter, true
        );
        emit PolicyUpdateScheduled(
            baseBurnBps_, graceBurnBps_, epochModulus_, graceLengthSubunits_, executeAfter
        );
    }

    function cancelPolicyUpdate() external onlyOwner {
        if (!pendingPolicy.exists) revert NoPendingUpdate();
        delete pendingPolicy;
        emit PolicyUpdateCancelled();
    }

    function executePolicyUpdate() external onlyOwner {
        PendingPolicy memory p = pendingPolicy;
        if (!p.exists) revert NoPendingUpdate();
        // Second-level timestamp manipulation is immaterial against a 1-day
        // timelock. See docs/process/STATIC-ANALYSIS.md sec 5.
        // slither-disable-start timestamp
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < p.executeAfter) revert TimelockActive(p.executeAfter);
        // slither-disable-end timestamp

        _apply(p.baseBurnBps, p.graceBurnBps, p.epochModulus, p.graceLengthSubunits);
        delete pendingPolicy;
    }

    function setExempt(address account, bool isExempt) external onlyOwner {
        exempt[account] = isExempt;
        emit ExemptionSet(account, isExempt);
    }

    // ─── IBurnController ────────────────────────────────────────────────

    /// @notice O(1), revert-free, as the token's gas-capped hook requires.
    ///         Returns exactly one of two rates for any timestamp:
    ///         `graceBurnBps` inside a window, `baseBurnBps` outside.
    function getBurnAmount(address from, address to, uint256 amount)
        external
        view
        override
        returns (uint256)
    {
        if (exempt[from] || exempt[to]) return 0;
        return (amount * _currentBps()) / BPS;
    }

    // ─── Frontend view helpers (design doc section 4) ───────────────────

    /// @notice The burn rate in force right now (bps).
    function currentBurnBps() external view returns (uint256) {
        return _currentBps();
    }

    /// @notice Whether a grace window is open right now.
    function graceActive() external view returns (bool) {
        return _graceActive();
    }

    /// @notice Seconds until the next window opens; 0 if one is open now.
    ///         Meaningless while `graceLengthSubunits == 0` (feature
    ///         disabled) — see the EpochLib note; frontends should gate the
    ///         countdown on a nonzero window length.
    function secondsUntilNextGrace() external view returns (uint256) {
        // The window schedule has 10-minute granularity; second-level
        // validator timestamp manipulation is immaterial to it. Start/end
        // form: the call spans multiple lines (adjacency rule,
        // docs/process/STATIC-ANALYSIS.md).
        // slither-disable-start timestamp
        return EpochLib.secondsUntilNextGrace(
            block.timestamp, anchor, epochModulus, graceLengthSubunits
        );
        // slither-disable-end timestamp
    }

    // ─── Internals ──────────────────────────────────────────────────────

    function _currentBps() internal view returns (uint256) {
        return _graceActive() ? graceBurnBps : baseBurnBps;
    }

    function _graceActive() internal view returns (bool) {
        // The window schedule has 10-minute granularity; second-level
        // validator timestamp manipulation is immaterial to it.
        // slither-disable-next-line timestamp
        return EpochLib.graceActive(block.timestamp, anchor, epochModulus, graceLengthSubunits);
    }

    function _validate(uint16 base_, uint16 grace_, uint32 modulus_, uint32 length_) internal pure {
        if (base_ > MAX_RATE_BPS) revert RateAboveCap(base_, MAX_RATE_BPS);
        if (grace_ > base_) revert GraceAboveBase(grace_, base_);
        if (modulus_ == 0) revert ZeroModulus(); // EpochLib panics by division on 0
        if (length_ > MAX_GRACE_LENGTH) revert GraceLengthAboveEpoch(length_, MAX_GRACE_LENGTH);
    }

    function _apply(uint16 base_, uint16 grace_, uint32 modulus_, uint32 length_) internal {
        baseBurnBps = base_;
        graceBurnBps = grace_;
        epochModulus = modulus_;
        graceLengthSubunits = length_;
        emit PolicyUpdated(base_, grace_, modulus_, length_);
    }
}
