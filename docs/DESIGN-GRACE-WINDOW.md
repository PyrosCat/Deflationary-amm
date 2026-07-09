# Design: Epoch grace window for the transfer burn

**Status:** Architecture decided (Session 3). Parameters TBD. Not implemented.
**Resolves:** Session 2 handoff, section 6a (all five questions).
**Supersedes:** nothing — this is the first design record for the mechanism.

---

## 1. Decision summary

The grace-window mechanism lives **entirely inside the `IBurnController`
implementation**. It is a parameterized schedule, not a hardcoded one:

- `epochModulus` — which epochs qualify for a grace window
  (`epoch % epochModulus == 0`; modulus 1 = every epoch)
- `graceLengthSubunits` — how many ten-minute subunits, from the start of a
  qualifying epoch, the window stays open (half-open: active while
  `subunit < graceLengthSubunits`)
- `graceBurnBps` — the burn rate inside the window (0 = fully burn-free;
  must never exceed the base rate)

Plus one **clock** parameter, distinct from the three policy parameters:

- `anchor` — the timestamp at which epoch 0 begins (v5's `epochStart`).
  `0` = unix anchoring, windows open at 00:00 / 08:00 / 16:00 UTC. Held as
  a **constructor immutable** in the controller (v5 parity), changed only by
  swapping the controller — never a live setter, which would silently
  re-bucket every epoch and move every window.

The three policy parameters are owner-settable behind the existing **1-day
timelock**. Changing the schedule is a parameter update; changing the
*mechanism* or the *clock* requires a controller swap.

The epoch/subunit math is provided by an **internal library** (`EpochLib`)
compiled into the controller — not a separately deployed contract. It is pure
view math; an external call buys nothing, and the controller is already the
replaceable unit.

**Scope:** the grace window applies to the **token transfer burn only**. The
AMM's swap burn earmark is a separate mechanism with separate purpose
(liquidity economics vs. supply economics) and remains independent.

**Not affected:** token contract (immutable, unchanged), pool contract,
proxy storage layout, `__gap`.

---

## 2. Provenance and the v5 relationship — VERIFIED

v5's recovered `EpochUtils.sol` was re-provided in Session 3 and is archived
**verbatim** at `archive/v5/EpochUtils.sol` (with a README; `archive/` is not
compiled). The diff against the spec-derived library is complete. Findings:

1. **v5 was NOT unix-anchored.** It took a constructor `epochStart`
   immutable; epoch 0 began at a deployment-chosen timestamp. The initial
   spec-derived draft's unix-0 assumption was wrong for v5. Resolution:
   `EpochLib` now takes an `anchor` parameter everywhere. `anchor == 0`
   gives unix anchoring (windows open at 00:00 / 08:00 / 16:00 UTC —
   human-legible); any other value reproduces v5 semantics.
2. **8-hour epoch and 10-minute subunit constants CONFIRMED.** The v5
   comment saying "12-hour epoch" is wrong, exactly as the Session 2
   handoff recorded — the constant is authoritative. The archived copy is
   deliberately unmodified (provenance); the correction lives in
   `archive/v5/README.md` and in `EpochLib`'s header.
3. **v5 clamped pre-anchor queries to zero** (both getters return 0 before
   `epochStart`). `EpochLib.epochOf`/`subunitOf` keep that clamp for
   parity. The grace predicates additionally define pre-anchor time as
   **not** in a window — without that rule, the raw clamp would read the
   entire pre-anchor period as (epoch 0, subunit 0) and grace it.
4. **v5 was a deployed `contract` reading `block.timestamp`.** v6 keeps the
   internal-library decision, with the timestamp passed as a parameter —
   pure, no state, directly fuzzable.

The owner confirmed the v5 behaviour: **a fixed burn-free grace window every
third epoch** (the full epoch was free). v6 is explicitly **not bound by
v5**. The parameterized design reproduces v5 exactly with
`epochModulus = 3, graceLengthSubunits = 48, graceBurnBps = 0` and a nonzero
anchor, and also expresses every alternative discussed (e.g. a one-hour
window every epoch: `1 / 6 / 0`, anchor 0).

---

## 3. Parameter choices

| Parameter | Launch value | Status |
|---|---|---|
| `epochModulus` | **TBD** | Recommended: 1 (window every epoch) |
| `graceLengthSubunits` | **TBD** | Recommended: 6 (first hour of the epoch) |
| `graceBurnBps` | **TBD** | Options: 0 (full opt-out) or ~50% of base (tax keeps doing supply work) |
| `anchor` | **TBD** | Recommended: 0 (unix; UTC-legible windows). Constructor immutable, not a setter. |

### Modulus / length tradeoff

| Config | Graced fraction of time | Max wait for next window |
|---|---|---|
| modulus 1, 6 subunits | 12.5% | ~7 h |
| modulus 3, 48 subunits (v5) | 33.3% | 16 h |
| modulus 3, 6 subunits | ~4.2% | ~23 h |

Rationale for the recommendation: frequent short windows give users *more*
opportunities to avoid the burn (the actual intent) while gracing less total
time than v5, and the max wait drops from 16 h to ~7 h. With the recommended
`anchor = 0` (unix anchoring), "the first hour of every epoch" is
human-legible: windows open at 00:00, 08:00, 16:00 UTC. A nonzero anchor
(v5 style) shifts every window to `anchor + k * 8 h` — legal, but give a
reason if chosen.

### Graced rate: zero vs. reduced

Transfer timing is elastic, so with a fully free window essentially all
discretionary transfer volume will route through it and the tax degenerates
into an urgency premium. That is acceptable if the philosophy is "users can
fully opt out" — and consistent with the plan for in-game sinks to be the
primary deflation engine — but a reduced rate (e.g. half of base) preserves
the reward-for-patience story while still burning on every transfer. Decide
before launch; either is expressible without a code change.

---

## 4. Semantics (normative)

- **Epoch:** `epoch = (timestamp - anchor) / 8 hours`; epoch 0 begins at
  `anchor` (0 = unix anchoring). Pre-anchor timestamps clamp to epoch 0
  (v5 parity).
- **Subunit:** `subunit = ((timestamp - anchor) % 8 hours) / 10 minutes`,
  range [0, 47]; pre-anchor clamps to 0 (v5 parity).
- **Pre-anchor rule:** pre-anchor time is NEVER inside a grace window —
  the first window opens exactly at the anchor. (Without this rule the raw
  clamps would grace the entire pre-anchor period.)
- **Qualifying epoch:** `epoch % epochModulus == 0`. `epochModulus` MUST be
  ≥ 1 (setter-enforced; the library will panic on 0 by division).
- **Window:** half-open. Active iff the epoch qualifies AND
  `subunit < graceLengthSubunits`. A 6-subunit window is active for exactly
  the first 3600 seconds of the epoch and **inactive at second 3600**.
  `graceLengthSubunits = 0` disables the feature; `48` graces the whole epoch.
- **Rate invariant:** the controller returns exactly one of two values for
  any timestamp: `baseBurnBps` or `graceBurnBps`, with
  `graceBurnBps <= baseBurnBps` (setter-enforced).
- **Gas:** the rate lookup is branch-light pure math and MUST stay
  comfortably inside the token's fail-open `try/catch` gas cap.

### Frontend view helpers (controller surface)

- `currentBurnBps()` — the rate in force right now
- `graceActive()` — boolean
- `secondsUntilNextGrace()` — 0 if active, else seconds until the next
  qualifying epoch opens

The countdown UI reads these directly; do not reimplement the clock in
JavaScript.

---

## 5. Economics and MEV (honest framing — quote this in user docs)

The pool is tax-exempt, so **swaps never pay the transfer burn**; the grace
window therefore cannot be arbitraged through the AMM, and LPs are not
harmed by it. What the window actually invites is large holders timing
wallet-to-wallet and exchange-deposit transfers into the graced period.

Consequences, stated plainly:

- Discretionary transfers will concentrate in the window.
- Burn revenue from the transfer tax is expected to be modest.
- Supply deflation is designed to come primarily from future in-game sinks;
  the transfer tax is secondary.
- The window is public and equally accessible — a transparent, deliberate
  discount, not a hidden extraction vector.

This section pre-answers the obvious audit question ("isn't a predictable
discount window a vulnerability?"): it is a feature with a known, accepted
cost, and the cost falls on protocol burn revenue, not on LPs.

---

## 6. Test plan

Unit tests for the epoch math ship with this bundle
(`test/EpochLib.t.sol`) and run standalone against the library (passing —
full suite 70 tests across 8 suites, 0 failures):

- constants (28,800 s epoch, 600 s subunit, 48 per epoch)
- epoch counting from unix 0; rollover boundaries
- subunit boundaries (0 / 599 / 600 / 28,799 / 28,800)
- half-open window: active at close−1 s, inactive at close (with the
  `len = 48` full-epoch special case)
- modulus 3 + full epoch reproduces v5
- zero-length disables
- anchor semantics: pre-anchor clamps on the raw getters (v5 parity),
  pre-anchor never graced, first window opens exactly at the anchor second
- fuzz: subunit always in [0, 47] for any anchor; epoch monotonic; warping
  forward by `secondsUntilNextGrace` always lands inside an active window
  (including from pre-anchor timestamps); pre-anchor never graced for any
  parameters

Controller integration tests are enumerated in
`test/GraceController.CHECKLIST.md` and must be written alongside the
controller implementation. This codebase has already been bitten once by
strict-`>` vs `>=` deadline ambiguity; the window boundary tests exist to
prevent the same bug class here.

---

## 7. Out of scope / future

- DAO-voted schedules, holiday windows, emergency pauses — future controller
  versions; the pluggable design accommodates them without token changes.
- Any coupling of the grace window to the AMM swap earmark — explicitly
  rejected (section 1).
