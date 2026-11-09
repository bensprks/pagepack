// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Entry, PagePack, PagedMap} from "pagepack/PagePack.sol";

// A typed map holding two kinds of entry of different sizes: each owner's two-slot Account and
// its one-slot Approvals, so a layout can put an account and its approvals on one page.
//
//     AccountMap internal immutable ACCOUNTS = accountMap("token.accounts");
//
//     ACCOUNTS.account(owner).balance -= amount;
//     ACCOUNTS.approval(owner, spender).amount -= amount;
//
// The map is created at the smaller kind's size, and each getter looks its kind up at its own
// struct's size, so a struct always fits its entry. Placements and hints come from a helper per
// kind that names the kind's size, so code driving the layout never handles one:
//
//     ACCOUNTS.map().rebalance(placements); // from accountPlacement, approvalPlacement
//     ACCOUNTS.map().useHints(hints);       // from ACCOUNTS.accountHint, ACCOUNTS.approvalHint

/// Two slots.
struct Account {
    uint256 balance;
    uint64 nonce;
    uint64 updatedAt;
}

/// One slot.
struct Approval {
    uint128 amount;
    uint64 expiry;
}

type AccountMap is bytes32;

using {account, accountHint, approval, approvalHint, map} for AccountMap global;

/// Creates the map with 50 entries per page, room for 25 accounts and one approval each. At the
/// default for one-slot entries, 64, the page's data would run out at 21 of each.
/// @dev Intended for an immutable.
function accountMap(string memory name) view returns (AccountMap) {
    return AccountMap.wrap(PagedMap.unwrap(PagePack.map(name, approvalSlots(), 50)));
}

/// The owner's account, wherever it currently lives. Look it up again after anything that
/// could rebalance.
function account(AccountMap entries, address owner) view returns (Account storage entry) {
    Entry e = entries.map().sized(accountSlots()).find(accountKey(owner));

    assembly ("memory-safe") {
        entry.slot := e
    }
}

/// What `spender` may still spend of the owner's balance.
function approval(AccountMap entries, address owner, address spender)
    view
    returns (Approval storage entry)
{
    Entry e = entries.map().sized(approvalSlots()).find(approvalKey(owner, spender));

    assembly ("memory-safe") {
        entry.slot := e
    }
}

/// The underlying map, for hints and rebalancing.
function map(AccountMap entries) pure returns (PagedMap) {
    return PagedMap.wrap(AccountMap.unwrap(entries));
}

// Placements and hints. A placement's size is part of the entry it names, so a wrong size would
// name another, empty entry and leave the intended one where it is. These take each kind's size
// from its struct.

/// Puts the owner's account at packed `index`, or sends it home if `index` is `PagePack.HOME`.
function accountPlacement(address owner, uint256 index) view returns (PagePack.Placement memory) {
    return PagePack.Placement(accountKey(owner), accountSlots(), index);
}

/// Puts an approval at packed `index`, or sends it home if `index` is `PagePack.HOME`.
function approvalPlacement(address owner, address spender, uint256 index)
    view
    returns (PagePack.Placement memory)
{
    return PagePack.Placement(approvalKey(owner, spender), approvalSlots(), index);
}

/// The account's hint for `useHints`, which carries its size. Meant for an eth_call wrapper.
function accountHint(AccountMap entries, address owner) view returns (PagePack.Hint memory) {
    bytes32 key = accountKey(owner);
    return PagePack.Hint(key, entries.map().sized(accountSlots()).hintOf(key));
}

/// An approval's hint for `useHints`. Meant for an eth_call wrapper.
function approvalHint(AccountMap entries, address owner, address spender)
    view
    returns (PagePack.Hint memory)
{
    bytes32 key = approvalKey(owner, spender);
    return PagePack.Hint(key, entries.map().sized(approvalSlots()).hintOf(key));
}

// Keys. An address is its own key. Two addresses don't fit in 32 bytes, so an approval's key is
// a hash, tagged so it can't equal any other kind's key.

function accountKey(address owner) pure returns (bytes32) {
    return bytes32(uint256(uint160(owner)));
}

function approvalKey(address owner, address spender) pure returns (bytes32) {
    return keccak256(abi.encode("approval", owner, spender));
}

// Sizes. A struct's size in slots is how far apart two of them sit in a storage array. These
// are `view` only because the compiler treats indexing a storage array as a possible read;
// nothing is read.

function accountSlots() view returns (uint256 slots) {
    Account[2] storage pair;
    assembly ("memory-safe") {
        pair.slot := 0
    }

    Account storage second = pair[1];
    assembly ("memory-safe") {
        slots := second.slot
    }
}

function approvalSlots() view returns (uint256 slots) {
    Approval[2] storage pair;
    assembly ("memory-safe") {
        pair.slot := 0
    }

    Approval storage second = pair[1];
    assembly ("memory-safe") {
        slots := second.slot
    }
}
