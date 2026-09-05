// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

import "../interfaces/IBurnController.sol";

/// @notice Fixed-supply deflationary ERC20 with a pluggable, hard-capped
///         transfer-burn policy. Supports EIP-2612 permit (gasless approvals)
///         and two-step ownership transfer.
///
///         Structural guarantees (enforced by THIS contract, not the owner):
///         - Supply can only ever decrease: minting happens once, in the
///           constructor. There is no mint function.
///         - The transfer tax can never exceed MAX_BURN_BPS (10%), no matter
///           what any controller returns. No honeypot switch exists.
///         - A broken, malicious, or gas-hungry controller can never freeze
///           transfers: the hook is called with a gas cap inside try/catch
///           and FAILS OPEN to zero tax.
///         - Controller changes are timelocked (1 day), giving holders a
///           review window. Scheduling address(0) disables the tax entirely.
///         - Tax burns are TRUE burns (totalSupply decreases), not
///           dead-address parking, so supply metrics on explorers are honest.
///
///         Tax semantics are SENDER-PAYS: the sender is debited exactly
///         `amount`; the recipient receives `amount - tax`. This is load-
///         bearing for AMM compatibility — pools that measure inbound funds
///         by balance delta and pay outbound by exact amount stay consistent.
contract DeflationaryToken is ERC20, ERC20Burnable, ERC20Permit, Ownable2Step {
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_BURN_BPS = 1_000; // hard 10% ceiling
    uint256 public constant CONTROLLER_UPDATE_DELAY = 1 days;
    uint256 internal constant CONTROLLER_CALL_GAS = 100_000;

    uint256 public immutable INITIAL_SUPPLY;

    IBurnController public burnController;

    struct PendingController {
        address newController;
        uint64 executeAfter;
        bool exists;
    }

    PendingController public pendingController;

    error ZeroAddress();
    error ZeroSupply();
    error ControllerNotContract();
    error NoPendingUpdate();
    error TimelockActive(uint64 executeAfter);

    event TaxBurned(address indexed from, address indexed to, uint256 amount);
    event ControllerUpdateScheduled(address indexed newController, uint64 executeAfter);
    event ControllerUpdateCancelled();
    event ControllerUpdated(address indexed newController);

    /// @param controller may be address(0) to launch with the tax disabled
    ///        (useful for deploy ordering: token first, controller later).
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply,
        address initialHolder,
        address controller
    ) ERC20(name_, symbol_) ERC20Permit(name_) Ownable(msg.sender) {
        if (initialHolder == address(0)) revert ZeroAddress();
        if (initialSupply == 0) revert ZeroSupply();
        if (controller != address(0) && controller.code.length == 0) revert ControllerNotContract();

        burnController = IBurnController(controller);
        INITIAL_SUPPLY = initialSupply;
        _mint(initialHolder, initialSupply);
    }

    // ─── Views ──────────────────────────────────────────────────────────

    /// @notice Total supply destroyed so far (tax burns + voluntary burns).
    /// @dev Derived, not stored: with true burns this identity always holds,
    ///      and it costs zero gas on the transfer hot path.
    function totalBurned() external view returns (uint256) {
        return INITIAL_SUPPLY - totalSupply();
    }

    // ─── Timelocked controller governance ──────────────────────────────

    function scheduleControllerUpdate(address newController) external onlyOwner {
        if (newController != address(0) && newController.code.length == 0) {
            revert ControllerNotContract();
        }
        // casting to 'uint64' is safe: block.timestamp + 1 day < 2**64 until year ~584e9
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 executeAfter = uint64(block.timestamp + CONTROLLER_UPDATE_DELAY);
        pendingController = PendingController(newController, executeAfter, true);
        emit ControllerUpdateScheduled(newController, executeAfter);
    }

    function cancelControllerUpdate() external onlyOwner {
        if (!pendingController.exists) revert NoPendingUpdate();
        delete pendingController;
        emit ControllerUpdateCancelled();
    }

    function executeControllerUpdate() external onlyOwner {
        PendingController memory p = pendingController;
        if (!p.exists) revert NoPendingUpdate();
        // Second-level timestamp manipulation is immaterial against a 1-day
        // timelock. See docs/process/STATIC-ANALYSIS.md sec 5.
        // slither-disable-start timestamp
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < p.executeAfter) revert TimelockActive(p.executeAfter);
        // slither-disable-end timestamp

        burnController = IBurnController(p.newController);
        delete pendingController;
        emit ControllerUpdated(p.newController);
    }

    // ─── Transfer hook ──────────────────────────────────────────────────

    /// @dev Mints (from == 0) and burns (to == 0) are never taxed — so
    ///      ERC20Burnable's burn/burnFrom always destroy exactly the stated
    ///      amount, which the pool's burn crank relies on when it verifies
    ///      balance deltas.
    function _update(address from, address to, uint256 amount) internal override {
        uint256 taxAmount = 0;

        if (from != address(0) && to != address(0) && address(burnController) != address(0)) {
            try burnController.getBurnAmount{gas: CONTROLLER_CALL_GAS}(from, to, amount) returns (uint256 t) {
                taxAmount = t;
            } catch {
                taxAmount = 0; // fail-open: a broken controller cannot freeze the token
            }

            uint256 maxTax = (amount * MAX_BURN_BPS) / BPS;
            if (taxAmount > maxTax) {
                taxAmount = maxTax;
            }
        }

        if (taxAmount > 0) {
            super._update(from, address(0), taxAmount); // true burn: reduces totalSupply
            emit TaxBurned(from, to, taxAmount);
        }

        super._update(from, to, amount - taxAmount);
    }
}
