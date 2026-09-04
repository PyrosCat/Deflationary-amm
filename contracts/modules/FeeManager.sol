// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../storage/LiquidityPoolStorage.sol";
import "../libraries/ERC20Utils.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IERC20Burnable {
    function burn(uint256 amount) external;
}

/// @notice Moves earmarked balances out of the pool.
///         - Protocol fees: owner-gated withdrawal.
///         - Burn balances: PERMISSIONLESS crank. Anyone may trigger the burn
///           because it can only ever destroy already-earmarked funds — this
///           mirrors the "burn crank" pattern and means deflation doesn't
///           depend on the owner showing up.
abstract contract FeeManager is LiquidityPoolStorage, OwnableUpgradeable {
    using ERC20Utils for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    error ZeroAddress();
    error NothingToBurn();

    event ProtocolFeesWithdrawn(address indexed to, uint256 amount0, uint256 amount1);
    event BurnExecuted(address indexed token, uint256 amount, bool trueBurn);

    // CEI: feeToken0/1 zeroed before transfers; the trailing event is benign. Sec 5.
    // slither-disable-start reentrancy-events
    function withdrawProtocolFees(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();

        uint256 f0 = feeToken0;
        uint256 f1 = feeToken1;
        // Effects before interactions.
        feeToken0 = 0;
        feeToken1 = 0;

        if (f0 > 0) token0.safeTransfer(to, f0);
        if (f1 > 0) token1.safeTransfer(to, f1);

        _syncReserves();
        emit ProtocolFeesWithdrawn(to, f0, f1);
    }
    // slither-disable-end reentrancy-events

    /// @notice Destroy all earmarked burn balances. Callable by anyone.
    function burnAccumulated() external {
        uint256 b0 = burnToken0;
        uint256 b1 = burnToken1;
        // Nothing-to-burn guard; == 0 is intended. See docs/process/STATIC-ANALYSIS.md sec 5.
        // slither-disable-next-line incorrect-equality
        if (b0 == 0 && b1 == 0) revert NothingToBurn();
        // Effects before interactions.
        burnToken0 = 0;
        burnToken1 = 0;

        if (b0 > 0) _burnOrDead(token0, b0);
        if (b1 > 0) _burnOrDead(token1, b1);

        _syncReserves();
    }

    /// @dev Try a real supply-reducing burn first; verify it actually reduced
    ///      our balance by exactly `amount` (guards against tokens whose
    ///      fallback swallows unknown calls). Otherwise park at the dead
    ///      address, which works for every ERC20.
    // slither-disable-start reentrancy-events
    // Events emitted after external calls are benign (no state depends on them);
    // effects precede interactions in the callers. See sec 5.
    function _burnOrDead(IERC20 token, uint256 amount) internal {
        uint256 balBefore = token.balanceOf(address(this));
        // Deliberate fail-open burn: probe the token's burn() and fall back to
        // the dead address if it reverts/no-ops. A low-level call is required to
        // catch tokens whose fallback swallows unknown selectors. See sec 5.
        // slither-disable-next-line low-level-calls
        (bool ok, ) = address(token).call(abi.encodeCall(IERC20Burnable.burn, (amount)));

        // Exact balance-delta verification is the whole point: confirm the burn
        // reduced our balance by precisely `amount` before trusting it. See sec 5.
        // slither-disable-next-line incorrect-equality
        if (ok && token.balanceOf(address(this)) == balBefore - amount) {
            emit BurnExecuted(address(token), amount, true);
        } else {
            token.safeTransfer(DEAD, amount);
            emit BurnExecuted(address(token), amount, false);
        }
    }
    // slither-disable-end reentrancy-events
}
