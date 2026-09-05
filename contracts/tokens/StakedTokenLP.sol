// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IStakedTokenLP.sol";

/// @notice LP share token for the AMM pool, with EIP-2612 permit for gasless
///         approvals (useful for future router/zap flows).
/// @dev The minter (the pool proxy) is set exactly ONCE and can never be
///      changed afterward — a mutable minter role is a pool-drain vector
///      (repoint minter → mint unlimited LP → withdraw everything).
///      After setMinter, ownership carries no dangerous powers and SHOULD be
///      renounced (plain Ownable is kept, rather than Ownable2Step, precisely
///      because renouncing is the intended end state).
contract StakedTokenLP is ERC20, ERC20Permit, Ownable, IStakedTokenLP {
    address public minter;

    event MinterSet(address indexed minter);

    error MinterAlreadySet();
    error NotMinter();
    error ZeroAddress();
    error NotAContract();

    constructor(string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
        Ownable(msg.sender)
    {}

    modifier onlyMinter() {
        if (msg.sender != minter) revert NotMinter();
        _;
    }

    /// @notice One-shot: bind the pool. Pass the pool PROXY address, not the
    ///         implementation address.
    function setMinter(address _minter) external onlyOwner {
        if (minter != address(0)) revert MinterAlreadySet();
        if (_minter == address(0)) revert ZeroAddress();
        if (_minter.code.length == 0) revert NotAContract();
        minter = _minter;
        emit MinterSet(_minter);
    }

    function mint(address to, uint256 amount) external override onlyMinter {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external override onlyMinter {
        _burn(from, amount);
    }
}
