// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "../helpers/TestBase.sol";
import {AMMLiquidityPool} from "../../contracts/AMMLiquidityPool.sol";
import {StakedTokenLP} from "../../contracts/tokens/StakedTokenLP.sol";

/// Handler: the fuzzer's only entry point. Bounds inputs to keep most calls
/// meaningful, and records ghost state for cross-call properties.
contract PoolHandler is Test {
    AMMLiquidityPool public pool;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    StakedTokenLP public lp;

    bool public ghost_kDecreasedOnSwap;

    constructor(AMMLiquidityPool _pool, MockERC20 _a, MockERC20 _b, StakedTokenLP _lp) {
        pool = _pool;
        tokenA = _a;
        tokenB = _b;
        lp = _lp;
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
    }

    function deposit(uint96 a0, uint96 a1) external {
        uint256 x0 = bound(uint256(a0), 1e9, 1e24);
        uint256 x1 = bound(uint256(a1), 1e9, 1e24);
        tokenA.mint(address(this), x0);
        tokenB.mint(address(this), x1);
        pool.deposit(x0, x1, 0, block.timestamp + 1);
    }

    function withdraw(uint96 seed) external {
        uint256 bal = lp.balanceOf(address(this));
        if (bal == 0) return;
        uint256 amt = bound(uint256(seed), 1, bal);
        pool.withdraw(amt, 0, 0, block.timestamp + 1);
    }

    function swap(bool zeroForOne, uint96 seed) external {
        uint256 rIn = zeroForOne ? pool.reserve0() : pool.reserve1();
        if (rIn < 1e6) return;
        uint256 amt = bound(uint256(seed), 1e3, rIn / 2);

        MockERC20 tin = zeroForOne ? tokenA : tokenB;
        tin.mint(address(this), amt);

        uint256 kBefore = pool.reserve0() * pool.reserve1();
        pool.swap(address(tin), amt, 0, block.timestamp + 1);
        uint256 kAfter = pool.reserve0() * pool.reserve1();

        if (kAfter < kBefore) ghost_kDecreasedOnSwap = true;
    }

    function crank() external {
        if (pool.burnToken0() + pool.burnToken1() == 0) return;
        pool.burnAccumulated();
    }

    function donateAndSync(uint96 seed) external {
        uint256 amt = bound(uint256(seed), 1, 1e21);
        tokenA.mint(address(pool), amt);
        pool.sync();
    }

    function warpTime(uint32 dt) external {
        vm.warp(block.timestamp + bound(uint256(dt), 1, 1 days));
    }
}

/// Global properties that must hold after ANY sequence of handler calls.
contract PoolInvariantsTest is Test {
    MockERC20 tokenA;
    MockERC20 tokenB;
    StakedTokenLP lp;
    AMMLiquidityPool pool;
    PoolHandler handler;

    address owner = makeAddr("owner");

    function setUp() public {
        tokenA = new MockERC20("TokenA", "TKA");
        tokenB = new MockERC20("TokenB", "TKB");
        lp = new StakedTokenLP("Pool LP", "PLP");

        pool = AMMLiquidityPool(
            address(
                new ERC1967Proxy(
                    address(new AMMLiquidityPool()),
                    abi.encodeCall(
                        AMMLiquidityPool.initialize,
                        (address(tokenA), address(tokenB), address(lp), owner)
                    )
                )
            )
        );
        lp.setMinter(address(pool));

        handler = new PoolHandler(pool, tokenA, tokenB, lp);
        targetContract(address(handler));
    }

    /// reserves == balance − earmarks, always, for both tokens.
    function invariant_ReserveAccountingIdentity() public view {
        assertEq(
            pool.reserve0(),
            tokenA.balanceOf(address(pool)) - pool.burnToken0() - pool.feeToken0()
        );
        assertEq(
            pool.reserve1(),
            tokenB.balanceOf(address(pool)) - pool.burnToken1() - pool.feeToken1()
        );
    }

    /// Earmarked funds are always actually present.
    function invariant_EarmarksBackedByBalances() public view {
        assertGe(tokenA.balanceOf(address(pool)), pool.burnToken0() + pool.feeToken0());
        assertGe(tokenB.balanceOf(address(pool)), pool.burnToken1() + pool.feeToken1());
    }

    /// Once liquidity exists, the minimum stays locked forever.
    function invariant_MinimumLiquidityLockedForever() public view {
        if (lp.totalSupply() > 0) {
            assertGe(lp.balanceOf(pool.DEAD()), pool.MINIMUM_LIQUIDITY());
        }
    }

    /// No swap in any fuzzed sequence ever decreased k (net of fees).
    function invariant_KNeverDecreasedOnSwap() public view {
        assertFalse(handler.ghost_kDecreasedOnSwap());
    }
}
