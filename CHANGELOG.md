# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/).

Versions follow `vMAJOR.MINOR.PATCH[-pre]`. See [docs/VERSION_CONTROL.md](docs/VERSION_CONTROL.md) for the full policy.

`v0.x` — pre-audit, pre-production. No stability guarantees on ABI or storage layout.

## [Unreleased]

_(nothing yet)_

---

## [v0.1.0-alpha.1] — 2026-07-05

First tagged commit. Contracts written and reviewed; not compiled, not executed,
not audited. Phase 0 of the roadmap complete (contract surface frozen).
Do not deploy to mainnet.

### Phase 0 — contract surface frozen
- EIP-2612 permit on `DeflationaryToken` and `StakedTokenLP`.
- Two-step ownership (`Ownable2Step`) on the pool and `DeflationaryToken`.
- All `require` strings converted to custom errors; data-carrying where useful
  (`SlippageExceeded(actual, minimum)`, `TimelockActive(executeAfter)`, `FeeAboveCap(requested, cap)`).
- TWAP oracle accumulators (Q112, Uniswap V2 semantics) in `_syncReserves`;
  storage gap reduced 40 → 37 to keep the layout footprint constant.
- `pendingFees` / `pendingSplit` made `public` for frontend readability.

### Added
- Full Foundry test suite (~1,070 lines across 7 files): unit, fuzz, invariant,
  proxy, and 3 regression tests pinning v5 bugs.
- CI: build + test + coverage + storage-layout diff + Slither + automated
  release workflow (`.github/workflows/`).
- Deployment scripts (`script/Deploy.s.sol`, `ActivateController`).
- Deployment records directory (`deployments/`) — empty pending first testnet run.
- Version control strategy: branching model, commit conventions, semver policy,
  release runbook (`docs/VERSION_CONTROL.md`).
- Repository scaffolding: `README.md`, `CONTRIBUTING.md`, `SECURITY.md`,
  `CHANGELOG.md`, `LICENSE`, `.gitignore`, `.env.example`, `INIT_REPO.sh`.
- Documentation: `docs/ARCHITECTURE.md`, `docs/TESTING.md`,
  `docs/HANDOFF-FRONTEND.md`, `docs/VERSION_CONTROL.md`.

### v6 rewrite (preceding this tag, included for provenance)
- Ground-up modular rewrite replacing the v5 monolith.
- Fixed swap pricing: uses stored pre-trade reserves (v5 double-counted input).
- Added `MINIMUM_LIQUIDITY` lock (first-depositor inflation attack).
- Balance-delta accounting on deposit and swap (fee-on-transfer safe).
- Three-way swap fee split (LP yield / burn / protocol); LPs previously earned nothing.
- Removed commit-reveal subsystem (bound nothing; not atomic; no real MEV protection).
- Production tokens: hard-capped fail-open burn controller, true burns,
  `ERC20Burnable`, one-shot LP minter.

### Not yet done (next milestones)
- `forge build` (milestone zero — see `docs/TESTING.md` section 11 for triage)
- `forge test` green
- `slither` triaged
- Testnet deployment
- Professional audit
- Ownership to multisig

[v0.1.0-alpha.1]: https://github.com/PyrosCat/Deflationary-amm/releases/tag/v0.1.0-alpha.1
