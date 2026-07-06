# Deflationary AMM

A modular, upgradeable (UUPS) constant-product AMM built to safely host fee-on-transfer deflationary tokens, with a three-way swap fee split (LP yield / burn / protocol), a permissionless burn crank, and a TWAP price oracle. Ships with a fixed-supply deflationary ERC-20 whose burn policy is pluggable but hard-capped.

> **v0.1.0-alpha.1** — pre-audit, pre-compile. Phase 0 complete (contract surface frozen). See [CHANGELOG](CHANGELOG.md). Unaudited.

## Highlights

- **Constant-product pool** with balance-delta accounting on the way in, so transfer-tax tokens work correctly (the core reason this exists).
- **Fixed-supply deflationary token** — no mint function; supply only ever decreases. Transfer burn is delegated to a swappable controller but can never exceed a 10% hard cap enforced by the token itself, and a broken controller can never freeze transfers (the hook fails open).
- **Three-way swap fee split** — LP yield stays in reserves, a burn share feeds deflation, a protocol share is withdrawable. All shares are timelocked and capped.
- **UUPS upgradeable** with a single centralized storage layout and a storage gap.
- **TWAP oracle** accumulators (Uniswap V2 Q112 semantics) for future on-chain pricing.
- **Full Foundry test suite** — unit, fuzz, invariant, proxy, and regression tests, the last pinning three specific bugs found in an earlier version.

## Contracts

| Contract | Role |
|---|---|
| `AMMLiquidityPool` | Main pool; UUPS orchestrator over the modules |
| `LiquidityPoolStorage` | Single source of truth for all state + upgrade gap |
| `FeeController` | Timelocked, capped fee governance |
| `FeeManager` | Protocol fee withdrawal + permissionless burn crank |
| `MathUtils` / `ERC20Utils` | Stateless math and safe-transfer libraries |
| `DeflationaryToken` | Fixed-supply ERC-20 with capped, fail-open transfer burn |
| `StakedTokenLP` | LP share token; minter bindable exactly once |
| `FlatRateBurnController` | Reference burn policy (flat rate + exemptions) |

## Getting started

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone <your-repo-url>
cd deflationary-amm

# dependencies (git submodules under lib/)
forge install foundry-rs/forge-std
forge install OpenZeppelin/openzeppelin-contracts@v5.1.0
forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.1.0

forge build
forge test -vvv
```

The satisfying first check — prove the three known bugs stay dead:

```bash
forge test --match-path test/Regression.t.sol -vvv
```

Full testing guide (including a Hardhat-to-Foundry translation): [docs/TESTING.md](docs/TESTING.md).

## Repository layout

```
contracts/          Solidity sources (pool, modules, libraries, tokens)
test/               Foundry suite (unit, fuzz, invariant, proxy, regression)
script/             Deployment scripts (forge script)
docs/               Architecture, testing, and frontend-integration docs
.github/            CI workflows and issue templates
```

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — full architecture, economic parameters, proxy design, roadmap, provenance
- [docs/TESTING.md](docs/TESTING.md) — Foundry setup and the test suite, for Hardhat users
- [docs/HANDOFF-FRONTEND.md](docs/HANDOFF-FRONTEND.md) — frontend integration and design handoff
- [SECURITY.md](SECURITY.md) — security posture and disclosure
- [CONTRIBUTING.md](CONTRIBUTING.md) — dev workflow and conventions
- [docs/VERSION_CONTROL.md](docs/VERSION_CONTROL.md) — branching, versioning, release process

## Deployment

The deploy scripts in `script/` encode the ordering the system requires (token → controller → LP token → pool proxy → one-shot `setMinter` → optional exemptions → timelocked controller activation). See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) section 4 for the full runbook. Copy `.env.example` to `.env` first.

```bash
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify
```

## Roadmap

Phase 0 (freeze the contract surface) is complete: permit, two-step ownership, custom errors, and the TWAP oracle are in. Current focus is Phase 1-2: compile, CI, and running the test suite. A Solana port is a later, separate milestone. Full roadmap in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) section 6.

## License

MIT — see [LICENSE](LICENSE).

## Disclaimer

Experimental, unaudited software provided as-is. Nothing here is financial or legal advice. Fee-on-transfer tokens, deflationary mechanics, and AMMs carry significant financial and regulatory risk. Do your own review and obtain a professional audit before deploying anything of value.
