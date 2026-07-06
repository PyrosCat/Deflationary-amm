# Frontend Handoff: AMM Pool + Deflationary Token

Audience: whoever designs and builds the web app for this protocol (designer, frontend dev, or future contributors).
Scope: the EVM contract system in this repo (`amm-pool-v6`). See section 12 before making any chain-coupled architecture decisions.
Companion doc: `docs/ARCHITECTURE.md` (contract architecture, deployment runbook, testing status).

---

## 1. What is being built

A dApp for a single constant-product AMM pool paired with a fixed-supply deflationary token. Four surfaces:

1. **Swap** - trade token0 <-> token1 through the pool
2. **Liquidity** - add/remove liquidity, view LP position
3. **Deflation dashboard** - live burn stats, supply chart, and a public "execute burn" action
4. **Governance** (owner-gated) - view and manage timelocked fee changes

The deflation dashboard is not an afterthought. The token's entire narrative is verifiable shrinking supply; this screen is the marketing site and the product at once.

## 2. Integration ground truth

- Contracts are drafted but **not compiled, deployed, or audited**. No addresses exist yet. Build against local Anvil deployments; treat all addresses as environment config.
- The pool is behind an ERC-1967 proxy. **The frontend talks to the proxy address only.** The implementation address should never appear in config.
- ABIs: generate from Foundry artifacts after `forge build` (wagmi CLI can emit typed hooks directly from `out/`).
- All three tokens use 18 decimals. All fee parameters are basis points (1 bps = 0.01%, denominator 10,000).
- All amounts are `uint256`. Use `bigint` end to end; format only at the presentation layer.
- No subgraph exists. For v1, read state via multicall and hydrate history from `eth_getLogs` on the events in section 8. Budget an indexer later if the burn feed gets heavy.

## 3. Screens and contract wiring

### 3.1 Swap

Reads: `getReserves()`, `quoteSwap(fromToken, amountIn)`, `swapFeeBps`, split getters, `paused()`, token balances/allowances, and (for tax display) `DeflationaryToken.burnController` -> `FlatRateBurnController.burnRateBps` + `exempt(pool)` + `exempt(user)`.

Write: `approve` (input token, spender = pool proxy) then `swap(fromToken, amountIn, minAmountOut, deadline)`.

Panel must show: rate, price impact, minimum received after slippage tolerance, the 1% pool fee **decomposed into its three destinations** (LP / burned / protocol), and, when the deflationary token is involved and untaxed status does not apply, the transfer tax line. "This swap will burn X tokens" is a feature, not fine print. Surface it.

### 3.2 Liquidity

Reads: `getReserves()`, `lpToken.totalSupply()`, `lpToken.balanceOf(user)`, `depositBurnBps`, `withdrawFeeBps`, `paused()`.

Writes: `approve` both tokens then `deposit(amount0, amount1, minLiquidityOut, deadline)`; `withdraw(lpAmount, minAmount0Out, minAmount1Out, deadline)` (no LP approval needed; the pool burns directly).

Add-liquidity form is **ratio-locked**: user edits one field, the other auto-fills from reserves (formula in section 6). Free-form entry of both amounts must not be the default; see rule U2.

Position card: share of pool, underlying token amounts, and a withdraw preview that is explicitly net of the exit fee ("You will receive ~X and ~Y after the 0.25% exit fee, which stays with remaining LPs").

First-ever deposit (totalSupply == 0): show a one-time note that 1,000 wei of LP is permanently locked (MINIMUM_LIQUIDITY). Cosmetic amount, but unexplained missing LP generates support tickets.

### 3.3 Deflation dashboard

Reads: `DeflationaryToken.totalSupply()`, `INITIAL_SUPPLY()`, `totalBurned()`, pool `burnToken0`/`burnToken1` (pending, not yet destroyed), controller rate and exemptions.

Write: `burnAccumulated()` - **permissionless**. Render as a public "Execute burn" button with the pending amounts beside it; disable with reason when both are zero (the contract reverts NOTHING_TO_BURN). Caller pays gas; say so.

History: supply-over-time chart and a live burn feed built from `TaxBurned` (token) + `BurnExecuted` (pool crank) + `Swapped.burnFee` events.

### 3.4 Governance (owner only)

Gate by comparing connected address to `owner()`; hide, don't disable, for non-owners.
Reads: current fee values, `pendingFees(feeType)` and `pendingSplit` (value, `executeAfter`).
Writes: `scheduleFeeUpdate`, `executeFeeUpdate`, `cancelFeeUpdate`, `scheduleSplitUpdate`, `executeSplitUpdate`, `cancelSplitUpdate`, `pause`, `unpause`, `withdrawProtocolFees(to)`.

Each pending change renders as a card with a countdown to `executeAfter`; "Execute" enables only after it elapses (contract enforces TIMELOCK_ACTIVE regardless). Validate caps client-side before submitting (deposit burn <= 2%, withdraw <= 2%, swap <= 5%, split sums to exactly 10,000). Pending changes are public information; consider a read-only "upcoming changes" strip on the swap screen for transparency.

## 4. Non-negotiable UX rules

These come from how the contracts work. Violating them produces wrong numbers or lost funds.

- **U1. Tax-adjusted quotes.** `quoteSwap` cannot see the token's transfer tax. When the input token is the deflationary token and neither sender nor pool is exempt, the pool receives less than the user sends; when it is the output token, the user receives less than the pool sends. Compute the displayed quote with the adjustment in section 6 or every taxed swap will look like mysterious slippage.
- **U2. Proportional deposits.** The pool mints LP on the min() of both sides; any excess of one token is silently absorbed by the pool. The ratio-locked form is the protection. If an advanced free-form mode exists, it must warn about the donated excess.
- **U3. Withdraw is never disabled by pause.** When `paused()` is true, disable swap and deposit with a banner, but withdrawals must remain fully functional and visibly so. This is a trust feature; do not grey it out.
- **U4. Slippage controls on every write.** All three user actions take min-out plus deadline params. Defaults: 0.5% tolerance (raise the suggestion when a transfer tax applies), 20-minute deadline, both user-adjustable in settings.
- **U5. Approvals target the proxy.** Exact-amount approval is the default; infinite approval is an explicit opt-in toggle. Sender-pays tax semantics mean an approval of exactly `amountIn` is sufficient even for the taxed token.
- **U6. Never call `initialize`, never surface implementation or module internals.** One pool, one proxy address.

## 5. Contract quick reference

| Action | Call | Notes |
|---|---|---|
| Quote a swap | `quoteSwap(fromToken, amountIn)` view | Tax-blind; apply U1 |
| Swap | `swap(fromToken, amountIn, minAmountOut, deadline)` | Returns `amountOut` |
| Add liquidity | `deposit(amount0, amount1, minLiquidityOut, deadline)` | Returns `liquidity` |
| Remove liquidity | `withdraw(lpAmount, min0, min1, deadline)` | Returns both amounts |
| Reserves | `getReserves()` view | Pre-trade snapshot |
| Crank the burn | `burnAccumulated()` | Permissionless |
| Pool token pair | `token0()`, `token1()` views | Order is fixed at init |
| Supply destroyed | `token.totalBurned()` view | Derived, always exact |

## 6. Formulas the frontend owns

Let `r0, r1 = getReserves()`, `S = lpToken.totalSupply()`, `f = swapFeeBps`, `BPS = 10000`.

- **Counterpart deposit amount:** editing amount0 -> `amount1 = amount0 * r1 / r0` (and symmetrically).
- **Expected LP out:** `min(net0 * S / r0, net1 * S / r1)` where `net = amount * (BPS - depositBurnBps) / BPS`. `minLiquidityOut = expected * (BPS - toleranceBps) / BPS`.
- **Swap quote (vanilla input):** `inAfterFee = amountIn * (BPS - f) / BPS`; `out = inAfterFee * rOut / (rIn + inAfterFee)`.
- **Tax adjustment (U1):** if input token is taxed for this sender->pool transfer, first `effectiveIn = amountIn - controller.getBurnAmount(user, pool, amountIn)`, then run the quote on `effectiveIn`. If the output token is taxed pool->user, final display = `out - controller.getBurnAmount(pool, user, out)`. Calling `getBurnAmount` directly (it is a view) is more robust than reimplementing rate+exemption logic.
- **Price impact:** `1 - (out / amountInEffective) / (rOut / rIn)`.
- **Withdraw preview:** `gross_i = r_i * lp / S`; display `gross_i * (BPS - withdrawFeeBps) / BPS`.
- **Burn contribution of a swap:** `feeAmount * swapFeeBurnShareBps / BPS` where `feeAmount = actualIn * f / BPS`.

All math in `bigint`, floor division throughout (matches Solidity). Never route amounts through `Number`.

## 7. Error copy

Map revert reasons to interface copy. Errors state what happened and what to do; they do not apologize.

Note: all contract reverts are custom errors as of Phase 0. Match on decoded error names via the generated ABIs, not strings. Several errors carry data the copy uses directly (`SlippageExceeded` amounts, `TimelockActive` timestamp).

| Revert | Interface copy |
|---|---|
| `Expired()` | "This quote expired before the transaction confirmed. Review the updated rate and try again." |
| `SlippageExceeded(actual, minimum)` | "Price moved beyond your tolerance: you would receive {actual}, below your minimum of {minimum}. Refresh the quote or raise tolerance in settings." (amounts come from the error data) |
| `NoLiquidity()` | "This pool has no liquidity yet. Add liquidity to open trading." |
| `ZeroAmount()` / `ZeroLiquidityMinted()` / `ZeroOutput()` | "Amount is too small for this pool. Enter a larger amount." |
| `InsufficientInitialLiquidity()` | "The first deposit must be large enough to lock 1,000 wei of LP. Increase both amounts." |
| `NothingReceived()` | "The pool received no tokens. Check the token's transfer settings and try again." |
| `TimelockActive(executeAfter)` | "This change unlocks in {countdown}." (build the countdown from the timestamp in the error data) |
| `NoPendingUpdate()` | "No change is scheduled." |
| `NothingToBurn()` | "No tokens are queued for burning right now." |
| `FeeAboveCap(requested, cap)` / `SplitMustSumTo100()` / `RateAboveCap(requested, cap)` | Governance form validation copy; these should be caught client-side before submission and only reach the wallet if validation was bypassed. |
| `NotMinter()` / `OwnableUnauthorizedAccount(account)` | "This action is restricted to the protocol owner." |
| User rejected in wallet | "Transaction cancelled." (no error styling) |

## 8. Events for feeds and cache invalidation

- `Swapped(user, tokenIn, amountIn, tokenOut, amountOut, lpFee, burnFee, protocolFee)` - trade history, burn feed, refresh reserves
- `Deposit` / `Withdraw` - position and TVL refresh
- `ReservesSynced(reserve0, reserve1)` - the single cheapest signal to invalidate all pricing queries
- `BurnExecuted(token, amount, trueBurn)` - burn feed (crank)
- `TaxBurned(from, to, amount)` on the token - burn feed (transfer tax)
- `FeeUpdateScheduled/Updated/Cancelled`, `SplitUpdateScheduled/Updated/Cancelled` - governance cards and the public "upcoming changes" strip
- `Paused` / `Unpaused` - global banner state

## 9. Design direction

Proposal, not mandate; the one fixed requirement is that numbers read as trustworthy.

**Subject and audience.** A precision financial instrument that destroys its own supply, built by a quant. The audience is crypto-literate traders and LPs who inspect numbers before trusting them. The page's job is to make verifiable scarcity legible.

**Palette (dark, heat-accented):**
- `#0B0E11` graphite (app background)
- `#151A1F` slate (cards, elevated surfaces)
- `#E8E4DC` bone (primary text)
- `#FF5C33` ember (burn accents ONLY: burn stats, burn feed, TaxBurned moments)
- `#3D9C8B` verdigris (positive/confirm: LP yield, received amounts)
- `#8A93A0` steel (secondary text, rules, labels)

Ember is reserved exclusively for destruction. If everything glows orange, nothing burns.

**Type:** a grotesque with character for display (Space Grotesk or similar), a quiet humanist sans for body (Inter or similar), and a monospace for every numeral, address, and hash (IBM Plex Mono or JetBrains Mono). Tabular figures everywhere numbers appear; amounts must not jitter as they update.

**Signature element:** the supply counter. One large monospace figure of current total supply on the dashboard, ticking down on each indexed burn event with a brief ember flash on the digits that changed. It is the thesis of the whole product rendered as a number. Spend the motion budget here and almost nowhere else (respect `prefers-reduced-motion`; the flash degrades to a color change).

**Layout:** swap and liquidity are single-column, card-centered, max ~440px forms, boring on purpose. The dashboard is the expressive surface: supply counter as hero, supply-over-time chart beneath, burn feed as a right rail or below on mobile. Quality floor without announcing it: responsive to 360px, visible keyboard focus, WCAG AA contrast (verify ember on graphite for text-size usage; prefer it on large numerals and fills).

**Copy register:** plain verbs, sentence case, active voice. Buttons say what happens: "Swap", "Add liquidity", "Remove liquidity", "Execute burn", "Schedule fee change". A user manages a position, executes a burn, sets slippage tolerance; the words module, crank, earmark, proxy, and UUPS never appear in the interface. Loading states name the wait ("Waiting for wallet confirmation…", "Confirming on chain…"). Empty states invite action ("No liquidity yet. Be the first to add it.").

## 10. Suggested stack

Next.js (or Vite) + TypeScript, wagmi v2 + viem (typed hooks generated from Foundry artifacts), TanStack Query for cache with event-driven invalidation keyed on `ReservesSynced`, RainbowKit or ConnectKit for wallets, and a headless component layer (Radix or similar) styled to section 9. Local dev against Anvil with a seed script that deploys the runbook from docs/ARCHITECTURE.md section 4 and funds test accounts.

## 11. Definition of done, v1

- All four screens wired against a local Anvil deployment
- U1-U6 implemented and demonstrably correct (a taxed swap and an untaxed swap both settle within tolerance of their displayed quotes)
- Error copy table fully mapped; no raw revert strings reach the user
- Pause banner behavior verified, withdraw path proven live while paused
- Burn feed rendering all three burn event sources
- Responsive to 360px; keyboard-navigable; reduced motion respected

## 12. Open questions for product (answer before heavy build)

1. **EVM or Solana?** ANSWERED (2026-07-03): EVM for the current build; a Solana port is a later, separate milestone. The architectural requirement stands: isolate all chain access behind one typed data-layer adapter so the eventual port swaps the adapter, not the app. Sections 2, 5-8, and 10 are chain-coupled; section 9 and the screen inventory survive a port untouched.
2. Final fee parameters (deposit burn may go to 0) - affects which lines appear in the swap/deposit panels.
3. Will the pool be tax-exempt in the controller? Determines whether U1 is a live code path or dormant safeguard (build it regardless).
4. Token names, symbols, logo, and brand assets - all TBD; section 9 palette is a proposal pending brand work.
5. Network(s) and hosting for the indexing strategy (pure RPC vs. hosted indexer).
