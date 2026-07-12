# Grace-window controller — integration test checklist

The controller does not exist yet, so these cannot ship as code. Write them
alongside the implementation; every item maps to a normative statement in
`docs/design/DESIGN-GRACE-WINDOW.md` section 4. The `EpochLib.t.sol` suite covers
the pure math and is passing (full suite: 70 tests, 0 failures); this list
covers everything that requires the
controller and token wired together.

## Rate semantics

- [ ] **Two-value fuzz:** for any timestamp and any valid parameter set, the
      controller's returned rate is exactly `baseBurnBps` or `graceBurnBps` —
      never a third value.
- [ ] Transfer executed inside an active window burns at `graceBurnBps`.
- [ ] Transfer executed outside a window burns at `baseBurnBps`.
- [ ] **Boundary regression:** a transfer at the exact window-close second
      (e.g. epoch start + 3,600 s for a 6-subunit window) pays the BASE rate.
      This is the strict-`>` vs `>=` bug class that bit the deadline test in
      Session 2 — pin it here too.
- [ ] Transfer at the exact window-open second (epoch start) pays the graced
      rate.

## Parameter setters (timelocked)

- [ ] `epochModulus` setter rejects 0 (the library panics by division on 0;
      the guard lives in the setter).
- [ ] `graceBurnBps` setter rejects values greater than `baseBurnBps`
      (invariant: graced rate never exceeds base).
- [ ] `graceLengthSubunits` setter rejects values greater than 48 (or
      documents/normalizes them — decide, then test the decision).
- [ ] All three setters are owner-only and pass through the existing 1-day
      timelock; a non-owner call reverts; an unscheduled immediate change
      reverts.
- [ ] Reminder from Session 2 test bugs: `vm.prank` affects only the next
      call — do not let an inline `new` consume it (see
      `test_Upgrade_PreservesAllState` fix).

## Fail-open and gas

- [ ] The controller's rate lookup fits comfortably inside the token's
      `try/catch` gas cap (measure with `forge test --gas-report`; assert a
      ceiling in a test so regressions are caught).
- [ ] A reverting or gas-guzzling controller does not brick transfers
      (fail-open path already exists — add a case with the grace controller
      specifically).

## Scope isolation

- [ ] The AMM swap burn earmark is unchanged by grace-window state: a swap
      during an active window produces the same earmark as an identical swap
      outside one.
- [ ] The pool's tax exemption is unaffected: pool-involved transfers pay no
      transfer burn in or out of the window.

## View helpers

- [ ] `currentBurnBps()`, `graceActive()`, `secondsUntilNextGrace()` agree
      with each other and with `EpochLib` at boundary timestamps (open
      second, close − 1, close).

## Invariant suite additions

- [ ] Add to the existing fuzz invariants: total supply never increases
      regardless of grace state, and earmarks remain backed by balances when
      swaps and graced transfers interleave.

## Before merging

- [x] ~~Diff `EpochLib.sol` against the recovered v5 `EpochUtils.sol`~~ —
      DONE in Session 3; findings (anchor parameter, pre-anchor clamps,
      confirmed 8-hour constant) recorded in DESIGN doc section 2. The v5
      file is archived verbatim at `archive/v5/EpochUtils.sol`.
- [ ] `anchor` is a constructor immutable in the controller — there is NO
      setter for it (changing the clock silently re-buckets every epoch;
      a clock change requires a controller swap).
- [ ] Transfers before the anchor pay the BASE rate (pre-anchor is never
      graced), and a transfer at exactly the anchor second pays the graced
      rate (with `graceLengthSubunits >= 1`).
- [ ] `slither .` on the new controller; expect the usual `block-timestamp`
      finding on the epoch math — justify with an inline comment matching
      the existing suppression style (schedule granularity is 10 minutes;
      second-level validator manipulation is irrelevant).
