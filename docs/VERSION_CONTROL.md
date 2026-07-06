# Version control

Strategy, branching model, commit conventions, tagging, and release process for this repository.

---

## 1. Branching model

A lightweight trunk-based model suited to a small team working on a security-sensitive codebase. The rule of thumb: the shorter a branch lives, the less it can drift into a merge conflict or accumulate stale assumptions.

```
main                    always deployable; protected; never force-pushed
├── feat/twap-consumer  feature work
├── fix/oracle-skip     bug fix
├── test/invariant-lp   test additions only (no contract changes)
├── docs/handoff-update documentation only
├── chore/ci-slither    tooling / CI / dependencies
└── release/v1.0.0      release prep (version bumps, CHANGELOG, final review)
```

### Branch rules

| Branch | Created from | Merges into | Lifetime | Notes |
|---|---|---|---|---|
| `main` | — | — | permanent | Protected. Squash or merge commits only. No direct pushes. |
| `feat/*` | `main` | `main` via PR | days–weeks | One feature per branch. |
| `fix/*` | `main` | `main` via PR | hours–days | Bug fixes, including regression test. |
| `test/*` | `main` | `main` via PR | hours–days | Test additions with no contract changes. |
| `docs/*` | `main` | `main` via PR | hours–days | Docs and NatSpec only. |
| `chore/*` | `main` | `main` via PR | hours–days | CI, tooling, dependencies. |
| `release/vX.Y.Z` | `main` | `main` via PR | days | Version bumps, CHANGELOG freeze, final audit pre-check. |

### Protected branch settings (`main`)

Configure these in GitHub: Settings → Branches → Add rule.

- Require a pull request before merging
- Require status checks to pass (CI: build, test, slither)
- Require conversation resolution before merging
- Do not allow force pushes
- Do not allow deletion

---

## 2. Commit conventions

Format: `<type>(<scope>): <imperative subject>`, sentence case, no terminal period, ≤72 characters on the subject line. Body is optional for small changes; required when the *why* isn't obvious or when a breaking change is involved.

### Types

| Type | When to use |
|---|---|
| `feat` | New behavior visible to users or callers (new function, new event, new error) |
| `fix` | Corrects a bug; must reference the issue or describe the symptom |
| `test` | Adds or fixes tests; zero contract changes |
| `docs` | NatSpec, markdown, comments |
| `refactor` | Internal restructure, no behavior change |
| `chore` | CI, tooling, dependencies, `.gitignore`, scripts |
| `release` | Version bump, CHANGELOG entry, tag |
| `security` | Security fix; reference the private advisory when public |

### Scopes (optional but useful)

`pool`, `token`, `controller`, `lp`, `storage`, `oracle`, `fees`, `deploy`, `ci`, `docs`

### Examples

```
feat(pool): add quoteSwap view for frontend price feeds

fix(token): clamp tax to MAX_BURN_BPS before controller call

  The cap was applied after the controller returned, meaning a
  malicious controller could still cause integer underflow on the
  transfer. Cap is now enforced unconditionally after the try/catch.

  Closes #12.

test(regression): pin v5 double-count pricing bug

docs(handoff): update error table for custom error selectors

chore(ci): add slither workflow on push to main

release: v1.0.0

BREAKING CHANGE: FeeController.scheduleFeeUpdate signature changed.
  Before: scheduleFeeUpdate(uint8 feeType, uint16 bps)
  After:  scheduleFeeUpdate(FeeType feeType, uint16 bps)
  Update any off-chain callers.
```

### Breaking changes

Any change that alters a public ABI selector, changes event parameters, modifies storage layout, or changes behavior that callers depend on is a breaking change. Mark it:

- In the commit body: `BREAKING CHANGE: <description>`
- In the PR description
- In `CHANGELOG.md` under `### Breaking changes`
- As a major version bump in the tag (see section 4)

---

## 3. Pull request rules

**One concern per PR.** A PR that adds a feature and refactors something unrelated is two PRs. Reviewers can't reason about correctness and behavior change at the same time.

**PR title** follows the same `type(scope): subject` format as commit messages — the title becomes the squash-merge commit subject.

**PR checklist** (in `.github/pull_request_template.md`):
- `forge fmt --check` passes
- `forge build --sizes` passes
- `forge test -vvv` passes
- Bug fixes include a regression test
- Storage discipline respected
- Docs updated if surface changed

**Size guidance:**
- Under 200 lines of contract diff: one reviewer, same-day turnaround reasonable
- 200–500 lines: two reviewers, allow 24–48 hours
- 500+ lines: break it up if possible; if not, plan for a full async review cycle

**Merge strategy:** squash merge for `feat/*`, `fix/*`, `test/*`, `docs/*`, `chore/*`. Merge commit for `release/*` so the release commit stands alone in `git log`.

---

## 4. Versioning

Semantic versioning: `vMAJOR.MINOR.PATCH`.

| Increment | When |
|---|---|
| `MAJOR` | Breaking ABI change, storage layout change, behavior change requiring caller updates |
| `MINOR` | New functionality, backward-compatible (new view, new event, new error) |
| `PATCH` | Bug fix, test, docs, CI; no ABI or behavior change |

### Special pre-release labels

| Tag | Meaning |
|---|---|
| `v1.0.0-alpha.1` | Under active development, not feature-complete |
| `v1.0.0-beta.1` | Feature-complete, in audit or pre-audit testing |
| `v1.0.0-rc.1` | Release candidate; only critical fixes allowed |
| `v1.0.0` | Production release; post-audit |

**Current state:** the codebase is pre-`v1.0.0-alpha.1` — it has not been compiled or audited. The first tag should be cut only after `forge test` passes cleanly.

### Contract versioning vs. git versioning

Git tags version the *repository*. Deployed contracts are versioned by their address, not the tag. For each production deployment:

1. Tag the commit: `git tag -a v1.0.0 -m "Release v1.0.0"`
2. Record the deployment: add a row to `deployments/` (see section 6)
3. The implementation address goes in `CHANGELOG.md` under the release heading

Upgraded implementations get their own deployment record and a PATCH or MINOR bump depending on what changed. A storage-breaking upgrade is a MAJOR bump.

---

## 5. Tagging and releases

### Cutting a release

```bash
# 1. Branch from main
git checkout -b release/v1.0.0

# 2. Bump version references and freeze the CHANGELOG
#    - CHANGELOG.md: move [Unreleased] entries under [v1.0.0] with today's date
#    - Any version strings in NatSpec or docs

# 3. Final checks
forge fmt --check
forge build --sizes
forge test -vvv
forge coverage --report summary

# 4. PR to main, squash merge
# 5. Tag main at the merge commit
git checkout main && git pull
git tag -a v1.0.0 -m "Release v1.0.0

Summary of changes since v0.x:
- Feature A
- Bug fix B
- See CHANGELOG.md for the full list."

git push origin v1.0.0
```

### GitHub release

After pushing the tag, create a GitHub Release from it:
- Title: `v1.0.0`
- Body: paste the `[v1.0.0]` section from `CHANGELOG.md` verbatim
- Attach the audit report PDF if available
- Mark pre-audit releases as "Pre-release"

### Hotfixes

A critical bug found in a deployed contract:

```bash
git checkout -b fix/critical-issue-description main
# make fix + regression test
# PR to main, normal review
# after merge, patch-bump the tag
git tag -a v1.0.1 -m "Hotfix: description"
git push origin v1.0.1
```

If the fix requires a contract upgrade, follow the upgrade procedure in `docs/ARCHITECTURE.md` section 4.

---

## 6. Deployment records

Create `deployments/` at the root. One JSON file per network per deployment event.

```
deployments/
├── sepolia-v1.0.0-beta.json
└── mainnet-v1.0.0.json
```

File schema:

```json
{
  "network": "mainnet",
  "chainId": 1,
  "version": "v1.0.0",
  "commit": "abc1234",
  "deployedAt": "2026-01-01T00:00:00Z",
  "contracts": {
    "DeflationaryToken":      "0x...",
    "FlatRateBurnController": "0x...",
    "StakedTokenLP":          "0x...",
    "AMMLiquidityPool_impl":  "0x...",
    "AMMLiquidityPool_proxy": "0x..."
  },
  "owner": "0x...",
  "notes": "Initial deployment. Audit report: ipfs://..."
}
```

Commit deployment records to the repo. They are the canonical on-chain address book; the frontend and the `ActivateController` script should read from here rather than hardcoding addresses.

---

## 7. Dependency management

Dependencies live in `lib/` as git submodules. The versions pinned in `INIT_REPO.sh` and `CONTRIBUTING.md` are the source of truth.

```bash
# pin a dependency to a specific tag (do this rather than tracking HEAD)
git -C lib/openzeppelin-contracts checkout v5.1.0
git add lib/openzeppelin-contracts
git commit -m "chore: pin openzeppelin-contracts to v5.1.0"
```

To update a dependency:
1. Branch: `chore/bump-oz-v5.2.0`
2. Update the submodule, run the full test suite
3. Check for storage layout drift (`forge inspect ... storage-layout`)
4. PR with a summary of what changed in the dependency that affects us

Never update a dependency in the same commit as a contract change.

---

## 8. What never goes in git

Enforced by `.gitignore`, and by reviewing before every commit:

- `.env` or any file containing private keys, mnemonics, or API keys
- `out/`, `cache/` (Foundry build artifacts — always reproducible)
- `lib/` tracked directly (submodule pointers only, not the full source)
- Compiled ABIs checked in alongside source (generate from `forge build`)
- Any file over ~1MB that isn't a necessary binary asset
