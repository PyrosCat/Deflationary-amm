# Contributing

## Setup

```bash
forge install foundry-rs/forge-std
forge install OpenZeppelin/openzeppelin-contracts@v5.1.0
forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.1.0
forge build
forge test
```

## Branching

Branch from `main`, open a PR. Full branching model and merge strategy: [docs/VERSION_CONTROL.md](docs/VERSION_CONTROL.md).

```
feat/*     new behavior
fix/*      bug fix (regression test required)
test/*     tests only, zero contract changes
docs/*     documentation and NatSpec
chore/*    CI, tooling, dependencies
release/*  version bump + CHANGELOG freeze
```

## Commit format

`type(scope): imperative subject` — sentence case, no period, ≤72 characters. Body optional for small changes, required when the *why* isn't obvious or a breaking change is involved.

```
feat(pool): add quoteSwap view for frontend price feeds
fix(token): clamp tax before controller call, not after
test(regression): pin v5 double-count pricing bug
chore(ci): add slither workflow on push to main
```

Types: `feat` `fix` `test` `docs` `refactor` `chore` `release` `security`
Scopes: `pool` `token` `controller` `lp` `storage` `oracle` `fees` `deploy` `ci` `docs`

Breaking changes: add `BREAKING CHANGE: <desc>` in the commit body, note it in the PR description and `CHANGELOG.md`, bump MAJOR version. See [docs/VERSION_CONTROL.md](docs/VERSION_CONTROL.md) section 4.

## Code conventions

- Solidity `^0.8.20`, formatted with `forge fmt`.
- **Storage discipline (critical for UUPS):** all state lives in `LiquidityPoolStorage`. Modules declare constants, events, errors, and functions only — never state variables. New storage in an upgrade consumes gap slots, appended only, never reordered or retyped.
- Custom errors everywhere; carry data when the frontend or a caller can use it.
- Favor structural guarantees (caps, one-shot binds, fail-open) over trusting the owner.
- Match existing NatSpec density; every invariant a function relies on should be stated in a comment.

## Before requesting review

```bash
forge fmt --check
forge build --sizes
forge test -vvv
forge coverage --report summary
slither . || true
```

## PR size guidance

| Contract diff | Reviewers | Turnaround |
|---|---|---|
| < 200 lines | 1 | same day |
| 200–500 lines | 2 | 24–48 hours |
| 500+ lines | break it up | — |

## Versioning

`vMAJOR.MINOR.PATCH` — see [docs/VERSION_CONTROL.md](docs/VERSION_CONTROL.md) section 4 for the full policy and the release runbook.
