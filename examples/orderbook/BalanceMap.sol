// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Entry, PagePack, PagedMap} from "pagepack/PagePack.sol";

// A typed map: traders' Balances stored by pagepack and looked up by address. Copy this file for
// each kind of entry, renaming the struct, the key and the functions:
//
//     BalanceMap internal immutable BALANCES = balanceMap("book.balances");
//
//     BALANCES.find(maker).quote += cost;
//
// The map's width is the struct's size, so it always fits. Hints and rebalancing go through the
// underlying map: `BALANCES.map().useHints(hints)`, with keys from `balanceKey`.

/// One slot. Fixed-size fields only: an entry's location changes when it is packed.
struct Balance {
    uint128 base;
    uint128 quote;
}

type BalanceMap is bytes32;

using {find, map} for BalanceMap global;

/// Creates a map whose entries are as wide as a Balance.
/// @dev Intended for an immutable. Reverts if Balance grows past 127 slots.
function balanceMap(string memory name) view returns (BalanceMap) {
    return BalanceMap.wrap(PagedMap.unwrap(PagePack.map(name, _balanceSlots())));
}

/// The account's entry, wherever it currently lives. Look it up again after anything that could
/// rebalance.
function find(BalanceMap balances, address account) view returns (Balance storage balance) {
    Entry e = balances.map().find(balanceKey(account));

    assembly ("memory-safe") {
        balance.slot := e
    }
}

/// An address is its own key. pagepack hashes the map and key together, so a key only has to be
/// unique within its map: cast a single value, bit-pack a composite key that fits in 32 bytes,
/// and hash only keys longer than that.
function balanceKey(address account) pure returns (bytes32) {
    return bytes32(uint256(uint160(account)));
}

/// The underlying map, for hints and rebalancing.
function map(BalanceMap balances) pure returns (PagedMap) {
    return PagedMap.wrap(BalanceMap.unwrap(balances));
}

/// Balance's size in slots: how far apart two Balances sit in a storage array. `view` only
/// because the compiler treats indexing a storage array as a possible read; nothing is read.
function _balanceSlots() view returns (uint256 slots) {
    Balance[2] storage pair;
    assembly ("memory-safe") {
        pair.slot := 0
    }

    Balance storage second = pair[1];
    assembly ("memory-safe") {
        slots := second.slot
    }
}
