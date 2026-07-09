// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract EpochUtils {
    uint256 public immutable epochStart;      // UNIX timestamp when epoch 0 begins
    uint256 public constant EPOCH_DURATION = 8 hours; // 28,800 seconds
    uint256 public constant SUBUNIT_DURATION = 10 minutes; // 600 seconds

    constructor(uint256 _epochStart) {
        epochStart = _epochStart;
    }

    /// @notice Returns the current epoch number (0-based)
    function getCurrentEpoch() public view returns (uint256) {
        if (block.timestamp < epochStart) {
            return 0;
        }
        return (block.timestamp - epochStart) / EPOCH_DURATION;
    }

    /// @notice Returns how many 10-minute subunits have passed in the current 12-hour epoch
    function getCurrentSubunit() public view returns (uint256) {
        if (block.timestamp < epochStart) {
            return 0;
        }
        uint256 timeIntoEpoch = (block.timestamp - epochStart) % EPOCH_DURATION;
        return timeIntoEpoch / SUBUNIT_DURATION;
    }
}
