# archive/v5 — provenance only, not compiled

`EpochUtils.sol` is the file recovered from v5 at the end of Session 2 and
re-provided in Session 3. It is preserved here **verbatim** — do not fix or
modernize it; its value is as evidence of what v5 actually did.

Known facts about it (verified Session 3, recorded in
`docs/DESIGN-GRACE-WINDOW.md` section 2):

- The natspec on `getCurrentSubunit` says "12-hour epoch". That comment is
  **wrong**; `EPOCH_DURATION = 8 hours` is authoritative.
- It is a deployed `contract` reading `block.timestamp`, with a constructor
  `epochStart` anchor and pre-anchor clamps to zero on both getters.
- Its v5 consumer (the grace-period logic) was never recovered.

The v6 successor is `contracts/libraries/EpochLib.sol` — an internal, pure,
anchor-parameterized library verified against this file. Nothing in this
directory is imported by contracts, tests, or scripts, and `foundry.toml`
does not include it in any source path, so it is never compiled.
