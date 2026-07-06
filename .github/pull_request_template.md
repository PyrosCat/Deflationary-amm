## What & why

<!-- What does this change and why? Link any issue. -->

## Checklist

- [ ] `forge fmt --check` passes
- [ ] `forge build --sizes` passes
- [ ] `forge test -vvv` passes (new/changed behavior is covered)
- [ ] Bug fixes include a regression test that fails without the fix
- [ ] Storage discipline respected (no new state outside `LiquidityPoolStorage`; gap appended only)
- [ ] Docs updated if behavior or the public surface changed
