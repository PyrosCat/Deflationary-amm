# Security Policy

## Status

This code is **unaudited and pre-production**. As of this writing it has not been compiled or executed in a verified environment, has no professional audit, and must not be used to custody real value. Do not deploy to mainnet.

## Design posture

The system is built to make guarantees structural (enforced by contract code) rather than trust-based (dependent on the owner behaving). Notable properties:

- **Fixed token supply**: `DeflationaryToken` has no mint function; supply only decreases.
- **Hard-capped transfer tax (10%)**: enforced by the token regardless of what any burn controller returns — there is no honeypot switch.
- **Fail-open transfer hook**: a broken, malicious, or gas-hungry burn controller cannot freeze transfers (gas-capped call inside try/catch, defaulting to zero tax).
- **Timelocked governance**: fee changes and controller swaps sit behind a 1-day delay with hard caps enforced at schedule time.
- **Two-step ownership** on the pool and token; **one-shot minter** binding on the LP token.
- **Withdrawals are never pausable**: users can always exit.
- **Balance-delta accounting**: safe for fee-on-transfer tokens.
- **Minimum-liquidity lock**: mitigates the first-depositor inflation attack.

Known unsupported inputs: rebasing/reflection tokens whose balances change outside transfers (same limitation as Uniswap V2).

## Before mainnet (required)

1. `forge build` and full `forge test` green, including the invariant suite.
2. `slither` triaged; storage-layout diff in CI.
3. Professional third-party audit of core + periphery.
4. Ownership of pool, token, and LP token moved to a multisig.

## Reporting a vulnerability

Until a disclosure channel is set up, report privately via GitHub's **Report a vulnerability** (Security tab -> Advisories) rather than a public issue. Please include a description, affected contracts, and a reproduction (a failing Foundry test is ideal). Do not open a public issue for anything exploitable.
