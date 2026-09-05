// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IStakedTokenLP.sol";

/// @notice Single source of truth for ALL persistent state, inherited by every
///         module and by the main contract. Modules must never declare their
///         own state variables — constants, events, errors, and functions
///         only. This is what keeps the UUPS storage layout safe across
///         upgrades.
abstract contract LiquidityPoolStorage {
    // ─── Core addresses ────────────────────────────────────────────────
    IERC20 public token0;
    IERC20 public token1;
    IStakedTokenLP public lpToken;

    // ─── Reserves (pre-trade snapshot, synced after every operation) ───
    uint256 public reserve0;
    uint256 public reserve1;

    // ─── Earmarked balances (excluded from reserves) ───────────────────
    uint256 public burnToken0; // awaiting destruction via burnAccumulated()
    uint256 public burnToken1;
    uint256 public feeToken0; // protocol fees awaiting withdrawal
    uint256 public feeToken1;

    // ─── Fee configuration (basis points) ──────────────────────────────
    uint16 public depositBurnBps; // taken from each deposit, earmarked to burn
    uint16 public withdrawFeeBps; // exit fee, stays in reserves for remaining LPs
    uint16 public swapFeeBps; // total swap fee, split three ways below

    uint16 public swapFeeLpShareBps; // share of swap fee left in reserves (LP yield)
    uint16 public swapFeeBurnShareBps; // share earmarked for burning
    uint16 public swapFeeProtocolShareBps; // share earmarked for the protocol

    // ─── TWAP oracle accumulators (Uniswap V2 style) ────────────────────
    /// @dev Prices are Q112 fixed point; accumulators overflow-wrap BY DESIGN.
    ///      Consumers read at two moments and take the difference over the
    ///      elapsed time. blockTimestampLast wraps in 2106; deltas stay valid.
    uint256 public price0CumulativeLast; // token1 per token0
    uint256 public price1CumulativeLast; // token0 per token1
    uint32 public blockTimestampLast;

    // ─── Timelocked fee governance ──────────────────────────────────────
    enum FeeType {
        DepositBurn,
        WithdrawFee,
        SwapFee
    }

    struct PendingFee {
        uint16 newBps;
        uint64 executeAfter;
        bool exists;
    }

    struct PendingSplit {
        uint16 lpShare;
        uint16 burnShare;
        uint16 protocolShare;
        uint64 executeAfter;
        bool exists;
    }

    mapping(uint8 => PendingFee) public pendingFees; // keyed by uint8(FeeType); public so frontends can render pending changes
    PendingSplit public pendingSplit;

    // ─── Cross-module hook ──────────────────────────────────────────────
    /// @dev Implemented by the main contract; lets modules resync reserves
    ///      after they move earmarked balances.
    function _syncReserves() internal virtual;

    /// @dev Reserved slots for future storage in upgrades. Reduced from 40 to
    ///      37 when the three oracle slots were added, keeping the total
    ///      layout footprint constant.
    uint256[37] private __gap;
}
