// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {AMMLiquidityPool} from "../../contracts/AMMLiquidityPool.sol";
import {StakedTokenLP} from "../../contracts/tokens/StakedTokenLP.sol";
import {DeflationaryToken} from "../../contracts/tokens/DeflationaryToken.sol";
import {FlatRateBurnController} from "../../contracts/tokens/FlatRateBurnController.sol";

/// @dev Vanilla mintable ERC20 for pairing against.
contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Controller that tries to tax everything. The token must clamp it.
contract MaxTaxController {
    function getBurnAmount(address, address, uint256) external pure returns (uint256) {
        return type(uint256).max;
    }
}

/// @dev Controller that always reverts. The token must fail open.
contract RevertingController {
    function getBurnAmount(address, address, uint256) external pure returns (uint256) {
        revert("broken controller");
    }
}

/// @dev Controller that burns all forwarded gas. The token's gas cap must contain it.
contract GasBombController {
    function getBurnAmount(address, address, uint256) external pure returns (uint256 x) {
        while (true) {
            unchecked {
                x++;
            }
        }
    }
}

/// @dev Shared deployment: full system behind a real ERC1967 proxy.
abstract contract PoolTestBase is Test {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant Q112 = 2 ** 112;

    MockERC20 internal tokenA; // token0
    MockERC20 internal tokenB; // token1
    StakedTokenLP internal lp;
    AMMLiquidityPool internal impl;
    AMMLiquidityPool internal pool; // the proxy

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public virtual {
        tokenA = new MockERC20("TokenA", "TKA");
        tokenB = new MockERC20("TokenB", "TKB");
        lp = new StakedTokenLP("Pool LP", "PLP");

        impl = new AMMLiquidityPool();
        bytes memory init =
            abi.encodeCall(AMMLiquidityPool.initialize, (address(tokenA), address(tokenB), address(lp), owner));
        pool = AMMLiquidityPool(address(new ERC1967Proxy(address(impl), init)));
        lp.setMinter(address(pool));

        address[2] memory users = [alice, bob];
        for (uint256 i = 0; i < users.length; i++) {
            tokenA.mint(users[i], 1_000_000e18);
            tokenB.mint(users[i], 1_000_000e18);
            vm.startPrank(users[i]);
            tokenA.approve(address(pool), type(uint256).max);
            tokenB.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// @dev Alice seeds the pool. Returns minted liquidity.
    function _seed(uint256 a0, uint256 a1) internal returns (uint256 liq) {
        vm.prank(alice);
        liq = pool.deposit(a0, a1, 0, block.timestamp + 1);
    }

    /// @dev Mirrors the contract's swap math against explicit reserves.
    function _quoteOut(uint256 amountIn, uint256 rIn, uint256 rOut) internal view returns (uint256) {
        uint256 fee = (amountIn * pool.swapFeeBps()) / BPS;
        uint256 net = amountIn - fee;
        return (net * rOut) / (rIn + net);
    }

    /// @dev Mirrors the contract's deposit-burn math.
    function _netOfDepositBurn(uint256 amount) internal view returns (uint256) {
        return amount - (amount * pool.depositBurnBps()) / BPS;
    }

    /// @dev EIP-2612 signature helper (works for both project tokens).
    function _signPermit(
        uint256 pk,
        address token,
        address permitOwner,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 typehash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        uint256 nonce = IERC20Permit(token).nonces(permitOwner);
        bytes32 structHash = keccak256(abi.encode(typehash, permitOwner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IERC20Permit(token).DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(pk, digest);
    }
}
