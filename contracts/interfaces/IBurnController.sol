// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Pluggable burn policy consumed by DeflationaryToken.
/// @dev Extracted from DeflationaryToken.sol (Session 3) so implementations —
///      FlatRateBurnController today, the epoch grace-window controller next —
///      can import a 5-line interface instead of the entire token contract.
interface IBurnController {
    /// @notice Burn tax for a transfer. Must be cheap (O(1)) and revert-free;
    ///         the token calls it with a gas cap and treats any failure as 0.
    function getBurnAmount(address from, address to, uint256 amount) external view returns (uint256);
}
