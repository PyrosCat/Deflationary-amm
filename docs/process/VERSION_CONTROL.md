# Version control

Strategy, branching model, commit conventions, tagging, and release process for this repository.

---

## 1. Branching model

Direct-to-main trunk. Day-to-day work commits straight to `main`; branches are the exception, reserved for the categories below. The gate that matters is not which branch work happened on but this: **tags are only ever cut from a fully green CI state on GitHub.** Green means both status checks pass: `build & test` (ci.yml) and `slither` (slither.yml) — these are the exact check names GitHub reports and branch protection must require.

**Scope of this rule:** direct-to-main applies to the repository owner only. External contributions always go through branch and PR per [CONTRIBUTING.md](../../CONTRIBUTING.md) — the two documents describe two tiers, not a contradiction.

```
main                     default target for all work; tags cut here; never force-push past a tag
├── fix/slither-*        static-analysis fixes            (branch required)
├── fix/ci-*             CI / workflow fixes              (branch required)
├── release/vX.Y.Z       only when a release has problems (see section 5)
└── feat/* test/* docs/* chore/*   optional, owner's call
```

### When to branch

| Situation | Branch? |
|---|---|
| Slither / static-analysis fixes | **Required** |
| CI / workflow fixes | **Required** |
| A release with problems (red CI at the release commit, CHANGELOG conflict, botched tag) | **Required** (`release/vX.Y.Z`) |
| Everything else (contracts, tests, docs, chore) | Owner's call; direct to `main` is the default |

Rationale: Slither and CI fixes are push-to-test by nature — the debug loop generates commits whose only purpose is to trigger a runner. On a branch those cycles are contained and erased at squash-merge; on `main` they are permanent history.

### Branch mechanics

When a branch is used:

1. Enable branch protection on `main` for the duration (require PR; require status checks `build & test` and `slither`; no force pushes).
2. Work on the branch; push-to-test freely.
3. Merge via PR using **Squash and Merge**. The PR title becomes the squash commit subject and must follow commit format (section 2).
4. Disable branch protection after the merge.

### History cleanup on main

Debug or fixup commits made directly to `main` may be squashed with an interactive rebase before a tag is cut, under one hard rule: **only commits not yet reachable from any tag.** Once a tag points at or past a commit, that history is frozen. Never force-push over a tag; never rebase tagged history.

---

## 2. Commit conventions

Format: `<type>(<scope>): <imperative subject>`, sentence case, no terminal period, ≤72 characters on the subject line. Body is optional for small changes; required when the *why* isn't obvious or when a breaking change is involved.

**One concern per commit** — the mirror of the PR rule in section 3. A commit that fixes CI *and* changes `.gitignore` semantics is two commits.

Subjects are one-liners; detail belongs in the CHANGELOG, not the subject. On a push-to-test branch (section 1), interim commit messages are relaxed — they are erased at squash-merge — but the squash commit subject must comply.

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

**One concern per PR.** A PR that adds a feature and refactors something unrelated is two PRs. A reviewer (or a future you doing archaeology) can't reason about correctness and behavior change at the same time.

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

**Merge strategy:** **Squash and Merge** for every branch type, `release/*` included. One branch, one commit on `main`.

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

### Pre-release cadence (alpha)

Within a minor version, the **alpha counter is the working increment**:

| Move | Trigger |
|---|---|
| `vX.Y.0-alpha.N` → `alpha.N+1` | Owner's judgment: enough changes have accumulated **and** CI is fully green on GitHub. No mechanical trigger — noise commits don't force a tag, and a tag never absorbs a red state. |
| `vX.Y.0-alpha.*` → `vX.(Y+1).0-alpha.1` | Genuinely new capability begins: new contract surface, new architectural component, a fresh alpha series. |
| `alpha` → `beta` → `rc` → final | Unchanged (table above). |

A tag may absorb multiple pieces of in-flight work if that is what the first green state contains; the CHANGELOG section for that tag must list all of it.

**Current state:** `v0.2.0-alpha.1` — 98 tests green, fuzz invariants passing, Slither clean at `fail-on: all` with no suppressed detectors. Pre-audit, pre-deployment; no stability guarantees on ABI or storage layout.

### Contract versioning vs. git versioning

Git tags version the *repository*. Deployed contracts are versioned by their address, not the tag. For each production deployment:

1. Tag the commit: `git tag -a v1.0.0 -m "Release v1.0.0"`
2. Record the deployment: add a row to `deployments/` (see section 6)
3. The implementation address goes in `CHANGELOG.md` under the release heading

Upgraded implementations get their own deployment record and a PATCH or MINOR bump depending on what changed. A storage-breaking upgrade is a MAJOR bump.

---

## 5. Tagging and releases

### Cutting a release (default: no branch)

Tags are cut directly on `main` at a green commit:

```bash
# 1. CHANGELOG first. The release workflow extracts the [vX.Y.Z-alpha.N] section
#    for the GitHub Release body — no matching section means an empty release body.
#    Move [Unreleased] entries under a dated [vX.Y.Z-alpha.N] heading.
git add CHANGELOG.md
git commit -m "release: v0.2.0-alpha.2"

# 2. Optional: interactive rebase to squash debug commits (untagged history only — section 1)

# 3. Verify green ON GITHUB, not just locally — both checks: build & test, slither

# 4. Annotated tag, one-liner message; push with the tag
git tag -a v0.2.0-alpha.2 -m "v0.2.0-alpha.2 — Slither CI pin, submodule gitlinks"
git push origin main --follow-tags
```

Tag messages are **one-liners**. Detail lives in the CHANGELOG; the release workflow publishes that section as the GitHub Release body.

### Release branches — exception only

`release/vX.Y.Z` exists only when the release itself has problems: CI red at what should be the release commit, CHANGELOG conflicts, or a tag that needs repair. Normal releases never branch. When one is used, branch mechanics from section 1 apply (protection on, PR, Squash and Merge, protection off).

### GitHub release

`.github/workflows/release.yml` creates the GitHub Release automatically when a `v*` tag is pushed, extracting the matching `[vX.Y.Z]` CHANGELOG section as the body. After pushing a tag:

- Verify the release body is **non-empty** (an empty body means the CHANGELOG section was missing or misnamed)
- Mark pre-audit releases as "Pre-release"
- Attach the audit report PDF when one exists

### Hotfixes

A critical bug found in a deployed contract:

```bash
git checkout -b fix/critical-issue-description main
# fix + regression test; branch is required here — a deployed-contract fix is
# exactly the case where CI must validate before main moves
# PR, Squash and Merge, then patch-bump:
git tag -a v1.0.1 -m "v1.0.1 — hotfix: description"
git push origin v1.0.1
```

If the fix requires a contract upgrade, follow the upgrade procedure in `docs/design/ARCHITECTURE.md` section 4.

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

---

## 9. Documentation layout and session records

```
docs/
├── design/      architecture and design documents (frozen decisions)
├── process/     how work is done: version control, testing, static analysis
├── incidents/   post-mortems, named YYYY-MM-DD-short-slug.md
├── frontend/    handoff material for frontend integrators
└── sessions/    work session records, WORK_SESSION_N.md
```

**Session records:** every working session closes by committing
`docs/sessions/WORK_SESSION_N.md`, where N increments monotonically. A
previous session's file is **never overwritten** — these are the
authoritative record of decisions made, lessons earned, and open items.

The old convention — a single gitignored `SESSION_HANDOFF.md` at the repo
root, overwritten each session — is retired. It lost history: sessions 1
and 2 have no surviving record. Sessions 3 and 4 were recovered into
`docs/sessions/` when this rule was adopted.

**Incident reports** go in `docs/incidents/` in the same session the
incident is resolved; the CHANGELOG entry references the report, not the
other way around.
