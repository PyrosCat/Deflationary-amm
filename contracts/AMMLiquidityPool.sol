// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./modules/FeeController.sol";
import "./modules/FeeManager.sol";
import "./libraries/ERC20Utils.sol";
import "./libraries/MathUtils.sol";
import "./interfaces/IStakedTokenLP.sol";

/// @title AMM Liquidity Pool (v6, Phase 0 surface)
/// @notice Thin UUPS orchestrator over the module system. Key invariants:
///         1. Pricing ALWAYS uses stored pre-trade reserves, never live balances.
///         2. Incoming funds are ALWAYS measured by balance delta (fee-on-
///            transfer safe on the way in — required for transfer-tax tokens).
///         3. reserves == balance − earmarked(burn + protocol fee), resynced
///            after every state-changing operation.
///         4. Withdrawals are never pausable: users can always exit.
///         5. TWAP accumulators record the pre-trade price over each elapsed
///            period (Uniswap V2 semantics); they overflow-wrap by design.
/// @dev Ownership is two-step (Ownable2Step): transfers require the new owner
///      to accept. NOT supported: rebasing/reflection tokens whose balances
///      change outside transfers — same limitation as Uniswap V2.
contract AMMLiquidityPool is
    Initializable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    FeeController,
    FeeManager
{
    using ERC20Utils for IERC20;

    /// @dev Permanently locked on first deposit (minted to DEAD) to make the
    ///      first-depositor share-inflation attack uneconomical.
    uint256 public constant MINIMUM_LIQUIDITY = 1e3;

    /// @dev Q112 fixed point for oracle prices; accumulation is skipped for
    ///      reserves at or above 2**144 to rule out mul overflow (a reserve
    ///      that large is ~2.2e25 whole tokens at 18 decimals).
    uint256 internal constant Q112 = 2 ** 112;
    uint256 internal constant MAX_ORACLE_RESERVE = 2 ** 144;

    error Expired();
    error ZeroAmount();
    error IdenticalTokens();
    error NotAContract();
    error InvalidReserves();
    error NoLiquidity();
    error InvalidToken();
    error InvalidOutput();
    error SlippageExceeded(uint256 actual, uint256 minimum);
    error InsufficientInitialLiquidity();
    error ZeroLiquidityMinted();
    error ZeroOutput();
    error NothingReceived();

    event Deposit(
        address indexed user,
        uint256 liquidity,
        uint256 received0,
        uint256 received1,
        uint256 burn0,
        uint256 burn1
    );
    event Withdraw(address indexed user, uint256 lpAmount, uint256 amount0Out, uint256 amount1Out);
    event Swapped(
        address indexed user,
        address indexed tokenIn,
        uint256 amountIn,
        address indexed tokenOut,
        uint256 amountOut,
        uint256 lpFee,
        uint256 burnFee,
        uint256 protocolFee
    );
    event ReservesSynced(uint256 reserve0, uint256 reserve1);

    modifier ensure(uint256 deadline) {
        // User-chosen tx deadline (Uniswap V2 pattern); second-level validator
        // drift only shifts expiry by seconds and cannot advantage anyone.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _token0,
        address _token1,
        address _lpToken,
        address _owner
    ) external initializer {
        if (_token0 == address(0) || _token1 == address(0) || _lpToken == address(0) || _owner == address(0)) {
            revert ZeroAddress();
        }
        if (_token0 == _token1) revert IdenticalTokens();
        if (_token0.code.length == 0 || _token1.code.length == 0 || _lpToken.code.length == 0) {
            revert NotAContract();
        }

        __Ownable_init(_owner);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        lpToken = IStakedTokenLP(_lpToken);

        // Default fee schedule (all adjustable later via the FeeController timelock):
        depositBurnBps = 10;             // 0.10% of each deposit earmarked to burn
        withdrawFeeBps = 25;             // 0.25% exit fee — stays in reserves for remaining LPs
        swapFeeBps = 100;                // 1.00% total swap fee, split as:
        swapFeeLpShareBps = 5_000;       //   50% stays in reserves (LP yield)
        swapFeeBurnShareBps = 3_000;     //   30% earmarked for burning
        swapFeeProtocolShareBps = 2_000; //   20% earmarked for the protocol

        blockTimestampLast = uint32(block.timestamp);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ─── Ownership (diamond resolution) ─────────────────────────────────

    /// @dev Both Ownable2StepUpgradeable (inherited directly) and
    ///      OwnableUpgradeable (inherited via the modules) define these two
    ///      functions, so Solidity requires the most-derived contract to
    ///      disambiguate. Both resolve to the TWO-STEP behavior: transfers
    ///      set a pending owner and take effect only on acceptOwnership().
    function transferOwnership(address newOwner)
        public
        virtual
        override(OwnableUpgradeable, Ownable2StepUpgradeable)
        onlyOwner
    {
        Ownable2StepUpgradeable.transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner)
        internal
        virtual
        override(OwnableUpgradeable, Ownable2StepUpgradeable)
    {
        Ownable2StepUpgradeable._transferOwnership(newOwner);
    }

    // ─── Liquidity ──────────────────────────────────────────────────────

    /// @notice Add liquidity. Deposit at the CURRENT reserve ratio — the LP
    ///         amount is the min() across both sides (V2 semantics), so any
    ///         excess of one token is absorbed by the pool. Frontends should
    ///         quote proportional amounts from getReserves().
    function deposit(
        uint256 amount0,
        uint256 amount1,
        uint256 minLiquidityOut,
        uint256 deadline
    ) external nonReentrant whenNotPaused ensure(deadline) returns (uint256 liquidity) {
        if (amount0 == 0 || amount1 == 0) revert ZeroAmount();

        // Balance-delta measurement: what actually arrived, net of any
        // transfer tax the tokens themselves apply.
        uint256 received0 = _pullMeasured(token0, amount0);
        uint256 received1 = _pullMeasured(token1, amount1);

        uint256 burn0 = (received0 * depositBurnBps) / MathUtils.MAX_BPS;
        uint256 burn1 = (received1 * depositBurnBps) / MathUtils.MAX_BPS;
        uint256 net0 = received0 - burn0;
        uint256 net1 = received1 - burn1;

        uint256 supply = lpToken.totalSupply();

        if (supply == 0) {
            uint256 root = MathUtils.sqrt(net0 * net1);
            if (root <= MINIMUM_LIQUIDITY) revert InsufficientInitialLiquidity();
            lpToken.mint(DEAD, MINIMUM_LIQUIDITY); // permanently locked
            liquidity = root - MINIMUM_LIQUIDITY;
        } else {
            if (reserve0 == 0 || reserve1 == 0) revert InvalidReserves();
            // Stored reserves are the PRE-deposit snapshot: synced at the end
            // of the previous operation, before this deposit's transfers.
            liquidity = MathUtils.min(
                (net0 * supply) / reserve0,
                (net1 * supply) / reserve1
            );
        }

        if (liquidity == 0) revert ZeroLiquidityMinted();
        if (liquidity < minLiquidityOut) revert SlippageExceeded(liquidity, minLiquidityOut);

        burnToken0 += burn0;
        burnToken1 += burn1;

        lpToken.mint(msg.sender, liquidity);
        _syncReserves();

        emit Deposit(msg.sender, liquidity, received0, received1, burn0, burn1);
    }

    /// @notice Remove liquidity. Deliberately NOT pausable — exits are always
    ///         available. The exit fee is not earmarked anywhere: it simply
    ///         stays in reserves, accruing to the remaining LPs (anti-churn).
    function withdraw(
        uint256 lpAmount,
        uint256 minAmount0Out,
        uint256 minAmount1Out,
        uint256 deadline
    ) external nonReentrant ensure(deadline) returns (uint256 amount0Out, uint256 amount1Out) {
        if (lpAmount == 0) revert ZeroAmount();
        uint256 supply = lpToken.totalSupply();
        if (supply == 0) revert NoLiquidity();

        uint256 gross0 = (reserve0 * lpAmount) / supply;
        uint256 gross1 = (reserve1 * lpAmount) / supply;
        if (gross0 == 0 || gross1 == 0) revert ZeroOutput();

        // Burn shares before paying out.
        lpToken.burn(msg.sender, lpAmount);

        uint256 fee0 = (gross0 * withdrawFeeBps) / MathUtils.MAX_BPS;
        uint256 fee1 = (gross1 * withdrawFeeBps) / MathUtils.MAX_BPS;
        amount0Out = gross0 - fee0;
        amount1Out = gross1 - fee1;

        if (amount0Out < minAmount0Out) revert SlippageExceeded(amount0Out, minAmount0Out);
        if (amount1Out < minAmount1Out) revert SlippageExceeded(amount1Out, minAmount1Out);

        token0.safeTransfer(msg.sender, amount0Out);
        token1.safeTransfer(msg.sender, amount1Out);
        _syncReserves();

        emit Withdraw(msg.sender, lpAmount, amount0Out, amount1Out);
    }

    // ─── Swaps ──────────────────────────────────────────────────────────

    /// @notice Swap an exact input of one pool token for the other.
    /// @dev Pricing uses STORED pre-trade reserves. Reading live balances
    ///      here would double-count the input, since it is transferred in
    ///      before pricing (the v5 bug).
    function swap(
        address fromToken,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) external nonReentrant whenNotPaused ensure(deadline) returns (uint256 amountOut) {
        bool zeroForOne = fromToken == address(token0);
        if (!zeroForOne && fromToken != address(token1)) revert InvalidToken();
        if (amountIn == 0) revert ZeroAmount();

        (IERC20 inToken, IERC20 outToken) =
            zeroForOne ? (token0, token1) : (token1, token0);
        (uint256 reserveIn, uint256 reserveOut) =
            zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        if (reserveIn == 0 || reserveOut == 0) revert NoLiquidity();

        uint256 actualIn = _pullMeasured(inToken, amountIn);

        uint256 feeAmount = (actualIn * swapFeeBps) / MathUtils.MAX_BPS;
        uint256 amountInAfterFee = actualIn - feeAmount;

        amountOut = MathUtils.getAmountOut(amountInAfterFee, reserveIn, reserveOut);
        if (amountOut == 0 || amountOut >= reserveOut) revert InvalidOutput();
        if (amountOut < minAmountOut) revert SlippageExceeded(amountOut, minAmountOut);

        // Three-way fee split. The LP cut is the remainder (absorbs rounding
        // dust) and is never earmarked — it stays in reserves as LP yield.
        uint256 burnCut = (feeAmount * swapFeeBurnShareBps) / MathUtils.MAX_BPS;
        uint256 protocolCut = (feeAmount * swapFeeProtocolShareBps) / MathUtils.MAX_BPS;
        uint256 lpCut = feeAmount - burnCut - protocolCut;

        if (zeroForOne) {
            burnToken0 += burnCut;
            feeToken0 += protocolCut;
        } else {
            burnToken1 += burnCut;
            feeToken1 += protocolCut;
        }

        outToken.safeTransfer(msg.sender, amountOut);
        _syncReserves();

        emit Swapped(
            msg.sender,
            address(inToken),
            actualIn,
            address(outToken),
            amountOut,
            lpCut,
            burnCut,
            protocolCut
        );
    }

    // ─── Views ──────────────────────────────────────────────────────────

    function getReserves() external view returns (uint256, uint256) {
        return (reserve0, reserve1);
    }

    /// @notice Quote for a swap against current reserves.
    /// @dev Cannot account for any transfer tax the input token applies in
    ///      transit — for transfer-tax tokens the realized output is lower.
    function quoteSwap(address fromToken, uint256 amountIn) external view returns (uint256 amountOut) {
        bool zeroForOne = fromToken == address(token0);
        if (!zeroForOne && fromToken != address(token1)) revert InvalidToken();
        (uint256 reserveIn, uint256 reserveOut) =
            zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        uint256 feeAmount = (amountIn * swapFeeBps) / MathUtils.MAX_BPS;
        amountOut = MathUtils.getAmountOut(amountIn - feeAmount, reserveIn, reserveOut);
    }

    // ─── Maintenance ────────────────────────────────────────────────────

    /// @notice Absorb any direct token donations into reserves.
    function sync() external nonReentrant {
        _syncReserves();
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ─── Internal ───────────────────────────────────────────────────────

    /// @dev Pull `amount` from the caller and return what ACTUALLY arrived.
    function _pullMeasured(IERC20 token, uint256 amount) internal returns (uint256 received) {
        uint256 balBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        received = token.balanceOf(address(this)) - balBefore;
        if (received == 0) revert NothingReceived();
    }

    /// @dev Accumulate the oracle with the reserves that PREVAILED since the
    ///      last sync (i.e., BEFORE this sync overwrites them), then resync:
    ///      reserves = balance − earmarked. Called after every operation, so
    ///      stored reserves are always the pre-trade snapshot for the NEXT one.
    function _syncReserves() internal override {
        _accumulateOracle();
        reserve0 = token0.balanceOf(address(this)) - burnToken0 - feeToken0;
        reserve1 = token1.balanceOf(address(this)) - burnToken1 - feeToken1;
        emit ReservesSynced(reserve0, reserve1);
    }

    /// @dev Uniswap V2 semantics: cumulative price += spot price × elapsed
    ///      time, in Q112 fixed point, with intentional overflow wrapping.
    ///      Consumers snapshot at two moments and divide the delta by the
    ///      elapsed time for a manipulation-resistant TWAP.
    function _accumulateOracle() internal {
        uint32 blockTimestamp = uint32(block.timestamp);
        uint32 timeElapsed;
        unchecked {
            timeElapsed = blockTimestamp - blockTimestampLast; // wraps in 2106, deltas stay valid
        }

        uint256 r0 = reserve0;
        uint256 r1 = reserve1;

        if (
            timeElapsed > 0 &&
            r0 > 0 && r1 > 0 &&
            r0 < MAX_ORACLE_RESERVE && r1 < MAX_ORACLE_RESERVE
        ) {
            unchecked {
                // Divide-before-multiply is DELIBERATE (Uniswap V2 UQ112 form):
                // (r * Q112) / r' stays within 256 bits for reserves below
                // MAX_ORACLE_RESERVE; multiplying by timeElapsed first would
                // reintroduce the overflow this guard exists to prevent. The
                // sub-Q112 precision loss is bounded and inherent to the format.
                // forge-lint: disable-next-line(divide-before-multiply)
                price0CumulativeLast += ((r1 * Q112) / r0) * timeElapsed; // wraps by design
                // forge-lint: disable-next-line(divide-before-multiply)
                price1CumulativeLast += ((r0 * Q112) / r1) * timeElapsed; // wraps by design
            }
        }

        blockTimestampLast = blockTimestamp;
    }
}
