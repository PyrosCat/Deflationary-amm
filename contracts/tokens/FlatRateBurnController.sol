// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Reference IBurnController: flat burn rate with an exemption list.
///         Exempt the AMM pool if you don't want tax stacking on top of the
///         pool's own fee-split burn; exempt vesting/treasury contracts so
///         operational moves don't bleed supply.
/// @dev Rate changes here are instant but doubly bounded: by this contract's
///      MAX_RATE_BPS and by the token's own MAX_BURN_BPS hard cap. For full
///      timelock purity, wrap setBurnRate in the same pending/execute pattern
///      used by the token and pool (deliberately deferred: the controller is
///      swappable behind the token's 1-day timelock, so a hardened v2 can
///      replace it at any time).
contract FlatRateBurnController is Ownable {
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_RATE_BPS = 1_000; // mirrors the token's ceiling

    uint256 public burnRateBps;
    mapping(address => bool) public exempt;

    error RateAboveCap(uint256 requested, uint256 cap);

    event BurnRateSet(uint256 bps);
    event ExemptionSet(address indexed account, bool isExempt);

    constructor(uint256 initialRateBps) Ownable(msg.sender) {
        if (initialRateBps > MAX_RATE_BPS) revert RateAboveCap(initialRateBps, MAX_RATE_BPS);
        burnRateBps = initialRateBps;
        emit BurnRateSet(initialRateBps);
    }

    function setBurnRate(uint256 newRateBps) external onlyOwner {
        if (newRateBps > MAX_RATE_BPS) revert RateAboveCap(newRateBps, MAX_RATE_BPS);
        burnRateBps = newRateBps;
        emit BurnRateSet(newRateBps);
    }

    function setExempt(address account, bool isExempt) external onlyOwner {
        exempt[account] = isExempt;
        emit ExemptionSet(account, isExempt);
    }

    /// @notice O(1), revert-free, as the token's gas-capped hook requires.
    function getBurnAmount(address from, address to, uint256 amount) external view returns (uint256) {
        if (exempt[from] || exempt[to]) return 0;
        return (amount * burnRateBps) / BPS;
    }
}
