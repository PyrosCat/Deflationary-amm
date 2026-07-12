# Static analysis (Slither) — Windows / WSL2 guide

Slither is the project's static analyzer. It is one of the two required CI
checks (`build & test`, `slither`) named in `docs/process/VERSION_CONTROL.md`, and
running it clean is a gate before any audit. This doc is written for a
**Windows user who has never used Slither**, running it inside **WSL2**.

Status at time of writing: **run clean.** First run surfaced 35 findings
(WSL2); all triaged as false-positive or informational and either suppressed
inline with justifications or (naming-convention only) excluded in config.
A verifying re-run should report **0 results**. Re-verify after any contract
change.

---

## 1. What Slither is (and isn't)

Slither is a static analyzer for Solidity: it compiles the contracts and
walks the code for known vulnerability and code-quality patterns, without
executing anything. It is fast (seconds once compiled), runs in CI, and
catches a different class of problem than Foundry tests — tests prove
behavior on the inputs you thought of; Slither flags shapes of code that are
*often* wrong regardless of inputs.

It is **not** an audit. A clean Slither run is necessary, not sufficient.
Every constraint in `docs/sessions/WORK_SESSION_4.md` section 4 still holds: the code is
unaudited and pre-mainnet until a human audit completes.

Expect false positives — a meaningful fraction of findings on any real
project are noise. The discipline here is the same as the Session 2 lint
cleanup: **triage every finding, suppress only with a written justification,
never blanket-silence a detector** so a genuine future occurrence still
surfaces.

## 2. Why WSL2 and not Git Bash

Slither itself is Python and could in principle run anywhere, but it compiles
through `crytic-compile`, which shells out to `forge` and reads the build
artifacts back. Under Git Bash (MINGW64), the Unix↔Windows path translation
at that boundary is the classic source of `Unknown file` / compilation
errors, and `solc` management on native Windows is the least-tested path.
Inside WSL2, Slither is a first-class Linux tool and everything below works
as documented. CI runs Slither on Linux too (`slither-action` on
ubuntu-latest), so a WSL2 run matches CI exactly.

Alternative if you ever want zero setup: the `trailofbits/eth-security-toolbox`
Docker image ships Slither plus every major solc. Not needed if you follow
this doc.

---

## 3. One-time setup (WSL2)

### 3.1 Install WSL2 + Ubuntu (skip if you have it)

In **PowerShell as Administrator**:

```powershell
wsl --install
```

Reboot if prompted. This installs WSL2 with Ubuntu by default; on first
launch it asks you to create a Linux username/password (unrelated to your
Windows login). If WSL is already installed, `wsl --update` then
`wsl --install -d Ubuntu` adds Ubuntu. Check what you have with `wsl -l -v`
— you want VERSION 2.

From here on, **every command in this doc runs inside the Ubuntu (WSL2)
terminal**, not PowerShell, not Git Bash.

### 3.2 Get the repo visible in WSL2

Two options:

- **Easiest:** use your existing Windows checkout. Windows drives are
  mounted under `/mnt/`, so if the repo lives at
  `C:\Users\<you>\code\Deflationary-amm`, in WSL2 it is:

  ```bash
  cd /mnt/c/Users/<you>/code/Deflationary-amm
  ```

  Same working tree — edits made in WSL2 appear in Windows instantly and
  vice versa. Perfectly fine for Slither. (Compiles are somewhat slower
  across the `/mnt/c` boundary; acceptable here since Slither runs are
  occasional.)

- **Faster builds, optional:** clone a second copy inside the Linux
  filesystem (`~/code/Deflationary-amm`). Only worth it if the `/mnt/c`
  route feels slow. If you do this, remember it is a *separate checkout* —
  keep it in sync via git, and run the actual triage/suppression edits
  wherever your canonical checkout is.

### 3.3 Install Foundry inside WSL2

WSL2 is a separate OS: your Windows `forge.exe` does not exist there.
Install the Linux Foundry:

```bash
curl -L https://foundry.paradigm.xyz | bash
source ~/.bashrc      # or open a new terminal
foundryup
forge --version
```

Then prove the compile works before involving Slither at all — Slither can
never succeed where `forge build` fails:

```bash
cd /mnt/c/Users/<you>/code/Deflationary-amm   # your path
forge build
```

Expect the via-IR build to take minutes cold (Session 2 measured ~252 s);
that is normal for this repo.

### 3.4 Install Slither inside WSL2

Slither needs Python 3.10+. Ubuntu's default python3 qualifies; check with
`python3 --version`. Then, using `pipx` for a clean isolated install:

```bash
sudo apt update && sudo apt install -y python3-pip pipx
pipx ensurepath
# open a new terminal (or: source ~/.bashrc) so pipx's bin dir is on PATH
pipx install slither-analyzer==0.11.5   # pinned — must match slither.yml
slither --version                        # verify it prints 0.11.5
```

(`uv tool install slither-analyzer` is an equally good alternative if you
already use uv; `pip install slither-analyzer` in a venv also works. Pick
one; pipx is the least ceremony.)

You do **not** need to install `solc` or `solc-select`: Slither compiles
through Foundry here, and Foundry manages solc (pinned to 0.8.24 in
`foundry.toml`) automatically.

---

## 4. Run

From the repo root, inside WSL2:

```bash
slither .
```

That's it — `slither.config.json` at the root supplies remappings, path
filters (`lib|test|script|archive`), and dependency exclusion, so a bare
`slither .` resolves OpenZeppelin and forge-std exactly as `forge` does. Do
not pass `--solc-remaps` by hand; the config covers it. Run from the root,
not a subfolder — Slither needs the whole project to resolve imports.

Useful variants:

```bash
# machine-readable output for diffing runs over time
slither . --json slither-report.json

# human summary tables (contract inventory, complexity)
slither . --print human-summary

# markdown checklist you can paste into an issue
slither . --checklist
```

**Run it now, before the grace controller is written.** With the Session 3
patch the only new source is `contracts/libraries/EpochLib.sol` (pure,
stateless, no external calls). Establishing a clean baseline now means that
when the grace controller lands, any new finding is unambiguously
attributable to the controller and not to pre-existing code.

### Reading the output

Findings print grouped by detector, each with an impact (High / Medium /
Low / Informational / Optimization) and a confidence level, plus file:line
references. Impact is *potential* severity of the pattern, not a verdict
that your code is broken — a High-impact finding can still be a false
positive, and triage decides which.

### If it fails to compile

1. Confirm `forge build` succeeds in the same WSL2 terminal. If it doesn't,
   fix that first; Slither is downstream of it.
2. `Unknown file` errors pointing into `lib/` usually mean the path filters
   didn't apply — confirm you ran from the repo root and that
   `slither.config.json` is present there.
3. Version mismatch weirdness: `pipx upgrade slither-analyzer` and
   `foundryup` to get current, then retry.

---

## 5. Expected findings and their triage

These are anticipated from the patterns already documented in the Session 2
handoff (section 3b lint cleanup). Confirm against the actual run — do not
assume the list is complete or that every item will appear.

| Detector | Where | Verdict | Justification |
|---|---|---|---|
| `timestamp` (block-timestamp comparison) | swap deadline, timelocks, and the epoch math consumer | **false positive** | Second-level validator manipulation is irrelevant to day-scale timelocks, to a `>` deadline guard, and to a 10-minute-granularity epoch clock. Same reasoning as the Session 2 `block-timestamp` lint suppressions. |
| `divide-before-multiply` | pool UQ112 oracle accumulator | **false positive** | Uniswap V2 fixed-point form; dividing first keeps the intermediate within 256 bits. Multiplying first reintroduces the overflow `MAX_ORACLE_RESERVE` guards. Must not be "fixed." |
| `reentrancy-*` | burn crank → external controller call | **verify, do not assume** | The crank is permissionless and calls an external controller behind a gas-capped `try/catch`. Confirm Slither sees no state written after the external call (checks-effects-interactions). If it flags a genuine ordering, that is a real finding — fix it, don't suppress. |
| `naming-convention` | `_param` names, `__gap`, `INITIAL_SUPPLY` | **excluded in config** | All idiomatic Solidity that Slither's mixedCase rule misflags. Wholesale-excluded with rationale (see "Detector exclusions in config" below) rather than suppressed sevenfold. |
| `unused-return` / `assembly` / other informational | various, incl. OZ-derived | **informational** | Judge case by case. OZ-internal findings should already be filtered by `exclude_dependencies`; if one leaks through, filter the path, don't edit `lib/`. |

Note on `EpochLib`: it takes the timestamp as a **parameter** rather than
reading `block.timestamp` itself, so Slither may not flag the library at
all — the `timestamp` finding is more likely to land on the eventual
controller at the call site. Either way, justify it there when it appears.

**Genuine findings to take seriously** (from section 6b of the handoff):
reentrancy paths, access-control gaps, and storage-layout anomalies. A hit
in any of these three categories is real until proven otherwise.

---

## 6. Suppression house style

Suppress in code, next to the thing being suppressed, with a reason — never
globally in the config. This matches the inline lint-disable discipline from
Session 2 and keeps the justification reviewable in the diff.

**Adjacency is load-bearing.** Both `slither-disable-next-line` and
`forge-lint: disable-next-line` apply strictly to the very next line — a
comment line in between breaks the suppression silently (learned the hard
way in Session 3: inserting Slither comments between existing forge-lint
comments and their code re-fired five lint warnings). Therefore:
justification prose goes ABOVE, the machine directive sits IMMEDIATELY
above the code line.

```solidity
// 10-minute subunit granularity; second-level timestamp drift cannot move a
// grace-window boundary. See docs/process/STATIC-ANALYSIS.md section 5.
// slither-disable-next-line timestamp
if (block.timestamp >= windowClose) {
```

When a line needs BOTH tools suppressed, only one directive can be adjacent —
use a `slither-disable-start/end` block (which does not require adjacency)
and keep the forge-lint directive on the adjacent line:

```solidity
// <justification>
// slither-disable-start timestamp
// forge-lint: disable-next-line(block-timestamp)
if (block.timestamp < p.executeAfter) revert TimelockActive(p.executeAfter);
// slither-disable-end timestamp
```

For function-level findings (e.g. reentrancy attributed to a whole function
range), wrap the function in `slither-disable-start/end` rather than guessing
which line the finding maps to:

```solidity
// <justification>
// slither-disable-start reentrancy-no-eth,reentrancy-benign
function withdraw(...) external nonReentrant ... { ... }
// slither-disable-end reentrancy-no-eth,reentrancy-benign
```

Rules:
- One detector (or one tightly-related comma list) per suppression; do not
  stack unrelated detectors on one comment.
- Every suppression carries a one-line reason and, where the reasoning is
  non-obvious, a pointer to this doc's triage table.
- The config's `filter_paths` / `exclude_dependencies` handle *whole
  categories that are never relevant* (deps, tests, archive). Everything
  contract-side is triaged inline. Do not migrate an inline case into the
  config to make a number go down.

### Detector exclusions in config (the one exception to "triage inline")

`slither.config.json` sets `"detectors_to_exclude": "naming-convention"`.
This is deliberate and is the *only* detector excluded wholesale. Rationale
(JSON can't hold comments, so it lives here and must stay in sync):

- Leading-underscore initializer/constructor params (`_token0`, `_owner`,
  `_minter`) are the standard disambiguation from the state variable they
  set — the same convention OpenZeppelin uses throughout.
- `__gap` is the OZ upgradeable storage-gap idiom, spelled exactly as OZ
  spells it. It cannot be renamed without breaking the thing it implements.
- `INITIAL_SUPPLY` is a constant; SCREAMING_SNAKE_CASE is correct Solidity
  style, which Slither's mixedCase check flags anyway.

All seven findings were the same class of false positive — Slither's naming
rule disagreeing with idiomatic Solidity, not the code being irregular — so
a wholesale exclude is cleaner than seven inline suppressions that would
recur on every future initializer parameter. Trade-off accepted: a genuinely
badly-named future variable also won't be caught by Slither; `forge fmt` and
review cover that, and naming is the least consequential thing Slither
checks. If that trade ever feels wrong, drop the exclude and inline-suppress
the specific known-good names instead.

---

## 7. CI

`.github/workflows/slither.yml` runs `slither .` on pushes and PRs to
`main`, on Linux, with the same `slither.config.json`. The workflow fails
the check on any finding not suppressed inline or filtered by config — that
is the `slither` required status check referenced in
`docs/process/VERSION_CONTROL.md`.

### Version pinning — the pin is the authority

Local WSL2 and CI agree only because **both are pinned to the same
slither-analyzer version** (currently **0.11.5**). Neither environment is
authoritative by default; the pin is. This was earned the hard way: with CI
on 0.11.4 and local on 0.11.5, CI reported 3 findings local runs could not
reproduce — an upstream 0.11.4 defect emitted findings with no source
mapping, so `filter_paths` had nothing to match (fixed upstream in 0.11.5,
PR #2918). The config was never at fault. Full account:
`docs/incidents/2026-07-10-slither-ci.md`.

Rules:

- `slither.yml` pins `slither-version` and the local install pins the same
  number (`pipx install slither-analyzer==<pin>`). Upgrading is a deliberate
  commit that changes both, plus this document.
- The analyzer pin must be installable in the Python shipped by the pinned
  action image (0.11.5 needs Python ≥ 3.10, which forced slither-action
  v0.4.1 → v0.4.2). Bumping the analyzer across a `Requires-Python`
  boundary means bumping the action first. If dependabot ever covers
  `github-actions`, record this coupling as a comment in `dependabot.yml`.
- `slither.yml` also pins `solc-version` explicitly (the action guesses
  otherwise — it had been guessing 0.8.20 against a 0.8.24 codebase).

Triage locally in WSL2 first: a red Slither check on a PR should be rare,
because you ran `slither .` and resolved or justified everything before
pushing.

---

## 8. First-run checklist

- [ ] WSL2 + Ubuntu installed; repo reachable (e.g. `/mnt/c/...` path).
- [ ] Foundry installed **inside WSL2**; `forge build` succeeds there.
- [ ] Slither installed (`slither --version` prints inside WSL2).
- [ ] `slither .` runs to completion from the repo root without a
      compilation error.
- [ ] Every finding is either suppressed inline (with reason) or filtered by
      config (with the reason living here).
- [ ] The three "take seriously" categories — reentrancy, access control,
      storage layout — are clean or have a written, reviewed rationale.
- [ ] Update the status line in the header of this doc and record the result
      in the current session record (`docs/sessions/WORK_SESSION_N.md`).
- [ ] Commit config + any inline suppressions on a `chore/ci-slither` branch
      (the branch name `docs/process/VERSION_CONTROL.md` already anticipates).

---

## 9. Day-to-day cheat sheet

```bash
# open the project in WSL2
wsl                                            # from any Windows terminal
cd /mnt/c/Users/<you>/code/Deflationary-amm    # your path

# the run
slither .

# after changing contracts, force a fresh compile first if results look stale
forge build --force && slither .

# keep tools current (occasionally)
foundryup
pipx upgrade slither-analyzer
```
