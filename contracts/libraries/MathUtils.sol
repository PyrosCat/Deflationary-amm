// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Stateless math for the pool. `getAmountOut` deliberately takes
///         reserves as PARAMETERS (never reads balances) so it is immune by
///         construction to the "input counted twice" bug: the caller is
///         responsible for passing PRE-TRADE reserves.
library MathUtils {
    uint256 internal constant MAX_BPS = 10_000;

    error InsufficientLiquidity();

    function min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x < y ? x : y;
    }

    /// @dev Babylonian method.
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    /// @notice Constant-product output for an exact input.
    /// @param amountInAfterFee input amount with the swap fee already removed
    /// @param reserveIn  PRE-TRADE reserve of the input token
    /// @param reserveOut PRE-TRADE reserve of the output token
    /// @dev Single-division form (Uniswap V2 style): rounds down, which
    ///      favors the pool, and avoids the double rounding of k/newReserveIn.
    function getAmountOut(
        uint256 amountInAfterFee,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        amountOut = (amountInAfterFee * reserveOut) / (reserveIn + amountInAfterFee);
    }
}
