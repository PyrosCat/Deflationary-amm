// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolTestBase} from "./helpers/TestBase.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AMMLiquidityPool} from "../contracts/AMMLiquidityPool.sol";

/// @dev Upgrade target: same pool plus one new function. Inherits the
///      disabled-initializers constructor.
contract PoolV2Mock is AMMLiquidityPool {
    function version() external pure returns (string memory) {
        return "v2";
    }
}

/// UUPS proxy behavior: initialize-once, implementation lockout,
/// upgrade authorization, and full state survival across an upgrade.
contract ProxyTest is PoolTestBase {
    function test_InitializeTwice_Reverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        pool.initialize(address(tokenA), address(tokenB), address(lp), owner);
    }

    function test_RawImplementation_CannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(tokenA), address(tokenB), address(lp), owner);
    }

    function test_Upgrade_OnlyOwner() public {
        PoolV2Mock v2 = new PoolV2Mock();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice)
        );
        pool.upgradeToAndCall(address(v2), "");
    }

    function test_Upgrade_PreservesAllState() public {
        // Build up non-trivial state: reserves, earmarks, oracle history.
        _seed(1000e18, 1000e18);
        vm.warp(block.timestamp + 100);
        vm.prank(bob);
        pool.swap(address(tokenA), 50e18, 0, block.timestamp + 1);

        uint256 r0 = pool.reserve0();
        uint256 r1 = pool.reserve1();
        uint256 b0 = pool.burnToken0();
        uint256 f0 = pool.feeToken0();
        uint256 p0 = pool.price0CumulativeLast();
        uint256 supply = lp.totalSupply();
        uint16 fee = pool.swapFeeBps();

        vm.prank(owner);
        pool.upgradeToAndCall(address(new PoolV2Mock()), "");

        assertEq(PoolV2Mock(address(pool)).version(), "v2", "new logic live");
        assertEq(pool.reserve0(), r0, "reserve0 survived");
        assertEq(pool.reserve1(), r1, "reserve1 survived");
        assertEq(pool.burnToken0(), b0, "burn earmark survived");
        assertEq(pool.feeToken0(), f0, "protocol earmark survived");
        assertEq(pool.price0CumulativeLast(), p0, "oracle history survived");
        assertEq(lp.totalSupply(), supply, "LP supply untouched");
        assertEq(pool.swapFeeBps(), fee, "fee config survived");

        // And the pool still works.
        vm.prank(bob);
        pool.swap(address(tokenB), 10e18, 0, block.timestamp + 1);
    }
}
