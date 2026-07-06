// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../storage/LiquidityPoolStorage.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @notice Timelocked fee governance. One generic schedule/execute/cancel
///         path for the three scalar fees, plus a dedicated path for the
///         three-way swap-fee split. Hard caps are enforced at SCHEDULE time
///         so the contract itself rules out confiscatory fees — the timelock
///         is then a review window, not the only line of defense.
abstract contract FeeController is LiquidityPoolStorage, OwnableUpgradeable {
    uint256 public constant FEE_UPDATE_DELAY = 1 days;

    uint16 public constant MAX_DEPOSIT_BURN_BPS = 200; // 2%
    uint16 public constant MAX_WITHDRAW_FEE_BPS = 200; // 2%
    uint16 public constant MAX_SWAP_FEE_BPS = 500;     // 5%
    uint16 internal constant BPS_DENOMINATOR = 10_000;

    error FeeAboveCap(uint16 requested, uint16 cap);
    error NoPendingUpdate();
    error TimelockActive(uint64 executeAfter);
    error SplitMustSumTo100();

    event FeeUpdateScheduled(FeeType indexed feeType, uint16 newBps, uint64 executeAfter);
    event FeeUpdateCancelled(FeeType indexed feeType);
    event FeeUpdated(FeeType indexed feeType, uint16 newBps);
    event SplitUpdateScheduled(uint16 lpShare, uint16 burnShare, uint16 protocolShare, uint64 executeAfter);
    event SplitUpdateCancelled();
    event SplitUpdated(uint16 lpShare, uint16 burnShare, uint16 protocolShare);

    // ─── Scalar fees ────────────────────────────────────────────────────

    function scheduleFeeUpdate(FeeType feeType, uint16 newBps) external onlyOwner {
        uint16 cap = _maxFor(feeType);
        if (newBps > cap) revert FeeAboveCap(newBps, cap);

        uint64 executeAfter = uint64(block.timestamp + FEE_UPDATE_DELAY);
        pendingFees[uint8(feeType)] = PendingFee(newBps, executeAfter, true);
        emit FeeUpdateScheduled(feeType, newBps, executeAfter);
    }

    function cancelFeeUpdate(FeeType feeType) external onlyOwner {
        if (!pendingFees[uint8(feeType)].exists) revert NoPendingUpdate();
        delete pendingFees[uint8(feeType)];
        emit FeeUpdateCancelled(feeType);
    }

    function executeFeeUpdate(FeeType feeType) external onlyOwner {
        PendingFee memory p = pendingFees[uint8(feeType)];
        if (!p.exists) revert NoPendingUpdate();
        if (block.timestamp < p.executeAfter) revert TimelockActive(p.executeAfter);

        if (feeType == FeeType.DepositBurn) depositBurnBps = p.newBps;
        else if (feeType == FeeType.WithdrawFee) withdrawFeeBps = p.newBps;
        else swapFeeBps = p.newBps;

        delete pendingFees[uint8(feeType)];
        emit FeeUpdated(feeType, p.newBps);
    }

    // ─── Swap-fee split ─────────────────────────────────────────────────

    function scheduleSplitUpdate(uint16 lpShare, uint16 burnShare, uint16 protocolShare) external onlyOwner {
        if (uint256(lpShare) + burnShare + protocolShare != BPS_DENOMINATOR) revert SplitMustSumTo100();

        uint64 executeAfter = uint64(block.timestamp + FEE_UPDATE_DELAY);
        pendingSplit = PendingSplit(lpShare, burnShare, protocolShare, executeAfter, true);
        emit SplitUpdateScheduled(lpShare, burnShare, protocolShare, executeAfter);
    }

    function cancelSplitUpdate() external onlyOwner {
        if (!pendingSplit.exists) revert NoPendingUpdate();
        delete pendingSplit;
        emit SplitUpdateCancelled();
    }

    function executeSplitUpdate() external onlyOwner {
        PendingSplit memory p = pendingSplit;
        if (!p.exists) revert NoPendingUpdate();
        if (block.timestamp < p.executeAfter) revert TimelockActive(p.executeAfter);

        swapFeeLpShareBps = p.lpShare;
        swapFeeBurnShareBps = p.burnShare;
        swapFeeProtocolShareBps = p.protocolShare;

        delete pendingSplit;
        emit SplitUpdated(p.lpShare, p.burnShare, p.protocolShare);
    }

    // ─── Internal ───────────────────────────────────────────────────────

    function _maxFor(FeeType feeType) internal pure returns (uint16) {
        if (feeType == FeeType.DepositBurn) return MAX_DEPOSIT_BURN_BPS;
        if (feeType == FeeType.WithdrawFee) return MAX_WITHDRAW_FEE_BPS;
        return MAX_SWAP_FEE_BPS;
    }
}
