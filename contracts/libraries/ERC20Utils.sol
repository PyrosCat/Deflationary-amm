// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal safe-transfer helpers tolerating non-standard ERC20s
///         (missing return values), with an explicit code-existence check so
///         a call to an EOA can never silently "succeed".
library ERC20Utils {
    error NotAContract();
    error TransferFailed();
    error TransferFromFailed();

    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        if (address(token).code.length == 0) revert NotAContract();
        (bool success, bytes memory data) =
            address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!success || !(data.length == 0 || abi.decode(data, (bool)))) {
            revert TransferFailed();
        }
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        if (address(token).code.length == 0) revert NotAContract();
        (bool success, bytes memory data) =
            address(token).call(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
        if (!success || !(data.length == 0 || abi.decode(data, (bool)))) {
            revert TransferFromFailed();
        }
    }
}
