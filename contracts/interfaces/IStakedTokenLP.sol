// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice LP share token controlled by the pool.
/// @dev IMPORTANT: the implementing token MUST restrict mint() and burn()
///      to the pool contract only (e.g. an `onlyPool` modifier set at deploy).
///      If anyone else can mint, the pool is trivially drainable.
interface IStakedTokenLP is IERC20 {
    // totalSupply() and balanceOf() come from IERC20; only the pool-controlled
    // mint/burn are added here.
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}
