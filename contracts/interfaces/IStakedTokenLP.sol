// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice LP share token controlled by the pool.
/// @dev IMPORTANT: the implementing token MUST restrict mint() and burn()
///      to the pool contract only (e.g. an `onlyPool` modifier set at deploy).
///      If anyone else can mint, the pool is trivially drainable.
interface IStakedTokenLP {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}
