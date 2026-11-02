#!/usr/bin/env bash
# Builds a fresh Foundry project that depends on pagepack the way the README describes. The
# library's own tests can't catch installation problems, such as a remapping that resolves to
# the wrong directory.
set -euo pipefail

FORGE="${FORGE:-forge}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
consumer="$(mktemp -d)"
trap 'rm -rf "$consumer"' EXIT

# Stand in for `forge install`: the package with its own dependencies checked out, which is
# what confuses Foundry's automatic remapping.
mkdir -p "$consumer/lib/pagepack" "$consumer/src"
rsync -a --exclude .git --exclude out --exclude cache "$repo/" "$consumer/lib/pagepack/"

cat > "$consumer/foundry.toml" <<'TOML'
[profile.default]
src = "src"
libs = ["lib"]
solc = "0.8.38"
TOML

# Keep in sync with the remapping in the README's usage section.
echo 'pagepack/=lib/pagepack/src/' > "$consumer/remappings.txt"

# The README has users copy the typed map example into their own source.
cp "$repo/examples/orderbook/BalanceMap.sol" "$consumer/src/"

cat > "$consumer/src/Consumer.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Entry, PagePack, PagedMap} from "pagepack/PagePack.sol";
import {BalanceMap, balanceMap} from "./BalanceMap.sol";

contract Consumer {
    BalanceMap internal immutable BALANCES = balanceMap("consumer.balances");
    PagedMap internal immutable FEES = PagePack.map("consumer.fees", 1);

    function pay(address maker, uint128 amount) external {
        BALANCES.find(maker).quote += amount;
    }

    function feeOf(bytes32 key) external view returns (uint256) {
        return FEES.find(key).read(0);
    }

    function chargeFee(bytes32 key, uint256 amount) external {
        Entry fee = FEES.find(key);
        fee.write(0, fee.read(0) + amount);
    }
}
SOL

cd "$consumer"
"$FORGE" build
echo "Downstream consumer build succeeded."
