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
// The map lists each kind with its struct's size, and each key names its kind in its top byte,
// so a struct always fits its entry and nothing else ever passes a size. Code driving the layout
// names entries by key alone:
//
//     ACCOUNTS.map().rebalance(placements); // PagePack.Placement(accountKey(owner), index)
//     ACCOUNTS.map().useHints(hints);       // PagePack.Hint(key, ACCOUNTS.map().hintOf(key))

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

using {account, approval, map} for AccountMap global;

// The map's kinds, each the top byte of its keys.
uint256 constant APPROVAL = 0;
uint256 constant ACCOUNT = 1;

/// Creates the map. Its two kinds give it 50 entries per page by default: room for 25 accounts
/// and one approval each.
/// @dev Intended for an immutable.
function accountMap(string memory name) view returns (AccountMap) {
    PagedMap entries = PagePack.mapOfKinds(name)
        .withKind(APPROVAL, approvalSlots())
        .withKind(ACCOUNT, accountSlots());

    return AccountMap.wrap(PagedMap.unwrap(entries));
}

/// The owner's account, wherever it currently lives. Look it up again after anything that
/// could rebalance.
function account(AccountMap entries, address owner) view returns (Account storage entry) {
    Entry e = entries.map().find(accountKey(owner));

    assembly ("memory-safe") {
        entry.slot := e
    }
}

/// What `spender` may still spend of the owner's balance.
function approval(AccountMap entries, address owner, address spender)
    view
    returns (Approval storage entry)
{
    Entry e = entries.map().find(approvalKey(owner, spender));

    assembly ("memory-safe") {
        entry.slot := e
    }
}

/// The underlying map, for hints and rebalancing.
function map(AccountMap entries) pure returns (PagedMap) {
    return PagedMap.wrap(AccountMap.unwrap(entries));
}

// Keys. Each holds its kind in the top byte. An address fits in the 31 bytes below it. Two
// addresses don't, so an approval's key is a hash, cut to 31 bytes.

function accountKey(address owner) pure returns (bytes32) {
    return bytes32((ACCOUNT << 248) | uint160(owner));
}

function approvalKey(address owner, address spender) pure returns (bytes32) {
    return bytes32((APPROVAL << 248) | (uint256(keccak256(abi.encode(owner, spender))) >> 8));
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
