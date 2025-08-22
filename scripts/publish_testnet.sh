#!/usr/bin/env bash
set -euo pipefail

# 切到 contracts/frontline_game 目錄
cd "$(dirname "$0")/../contracts/frontline_game"

echo "==> Building Move package..."
sui move build

echo "==> Ensuring we are on testnet env..."
# 如果你還沒設定 testnet 環境，下面兩行會建立與切換（已存在則不影響）
sui client new-env --alias testnet --rpc https://fullnode.testnet.sui.io:443 || true
sui client switch --env testnet

echo "==> Current active address:"
sui client active-address

echo "==> Publishing to testnet..."
# gas budget 可以先抓寬一點；不足會報錯，之後再調小
sui client publish --gas-budget 200000000