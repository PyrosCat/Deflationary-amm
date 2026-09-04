#!/usr/bin/env bash
# One-time repository initialization. Run from the project root after unzipping.
set -euo pipefail

echo "==> git init"
git init -q

echo "==> installing dependencies as submodules (requires network)"
forge install foundry-rs/forge-std
forge install OpenZeppelin/openzeppelin-contracts@v5.1.0
forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.1.0

echo "==> first build"
forge build || echo "Build reported issues — see docs/process/TESTING.md section 11 for triage."

echo "==> initial commit"
git add .
git commit -q -m "Initial commit: deflationary AMM (contracts, tests, docs, CI)"

cat <<'NOTE'

Done. Next:
  1. Create an empty repo on GitHub (no README/license/gitignore — they exist here).
  2. git remote add origin git@github.com:<you>/deflationary-amm.git
  3. git branch -M main && git push -u origin main

Then: forge test -vvv
NOTE
