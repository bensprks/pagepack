// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Entry, PagePack, PagedMap} from "pagepack/PagePack.sol";

// A typed map: Loans stored by pagepack and looked up by loan id. Copy this file for each kind of
// entry, renaming the struct, the key and the functions:
//
//     LoanMap internal immutable LOANS = loanMap("app.loans");
//
//     LOANS.find(loanId).interest += 1;
//
// The map's width is the struct's size, so it always fits. Hints and rebalancing go through the
// underlying map: `LOANS.map().useHints(hints)`, with keys from `loanKey`.

/// Two slots: borrower, openedAt and rateBps share slot 0, and principal and interest share
/// slot 1. Fixed-size fields only: an entry's location changes when it is packed.
struct Loan {
    address borrower;
    uint64 openedAt;
    uint32 rateBps;
    uint128 principal;
    uint128 interest;
}

type LoanMap is bytes32;

using {find, map} for LoanMap global;

/// Creates a map whose entries are as wide as a Loan.
/// @dev Intended for an immutable. Reverts if Loan grows past 127 slots.
function loanMap(string memory name) view returns (LoanMap) {
    return LoanMap.wrap(PagedMap.unwrap(PagePack.map(name, _loanSlots())));
}

/// The loan's entry, wherever it currently lives. Look it up again after anything that could
/// rebalance.
function find(LoanMap loans, uint256 loanId) view returns (Loan storage loan) {
    Entry e = loans.map().find(loanKey(loanId));

    assembly ("memory-safe") {
        loan.slot := e
    }
}

/// A loan id is its own key. pagepack hashes the map and key together, so a key only has to be
/// unique within its map: cast a single value, bit-pack a composite key that fits in 32 bytes,
/// and hash only keys longer than that.
function loanKey(uint256 loanId) pure returns (bytes32) {
    return bytes32(loanId);
}

/// The underlying map, for hints and rebalancing.
function map(LoanMap loans) pure returns (PagedMap) {
    return PagedMap.wrap(LoanMap.unwrap(loans));
}

/// Loan's size in slots: how far apart two Loans sit in a storage array. `view` only because the
/// compiler treats indexing a storage array as a possible read; nothing is read.
function _loanSlots() view returns (uint256 slots) {
    Loan[2] storage pair;
    assembly ("memory-safe") {
        pair.slot := 0
    }

    Loan storage second = pair[1];
    assembly ("memory-safe") {
        slots := second.slot
    }
}
