// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PagePack, PagedMap, Record} from "pagepack/PagePack.sol";

// The exchange's records in one typed map, so a layout can mix kinds on a page: each active
// market maker's account, order slots and positions on one page, and every market's record on
// another.
//
//     ExchangeMap internal immutable RECORDS = exchangeMap("pagepack.exchange");
//
//     Position storage position = RECORDS.position(trader, market);
//
// Every kind shares the map's one-slot width, which is pinned rather than taken from a struct,
// so exchangeMap checks each struct against it when the map is created.

// Records. Solidity packs each struct's fields into one slot in declaration order, starting from
// the lowest bits.

struct Account {
    uint128 balance;
    uint64 locked; // margin locked by resting orders
    uint64 markets; // bitmap of markets with a position; markets are numbered below 64
}

/// A position's equity is size × mark − cost.
struct Position {
    int128 size;
    int128 cost; // the signed sum of size × price
}

/// Each account reuses a few order slots rather than a fresh storage entry per order.
struct Order {
    uint64 price;
    uint64 size;
    uint8 market;
    bool isAsk;
}

struct Market {
    uint64 markPrice;
    uint16 marginBps;
    uint16 takerFeeBps;
    uint64 lastPrice;
    uint96 volume;
}

type ExchangeMap is bytes32;

using {account, position, order, market, map} for ExchangeMap global;

// Each key holds its kind in the top byte, so keys never collide across kinds, and its natural
// key bit-packed below. Nothing is hashed: pagepack hashes the map and key together.
uint256 constant ACCOUNT_KIND = 1 << 248;
uint256 constant POSITION_KIND = 2 << 248;
uint256 constant ORDER_KIND = 3 << 248;
uint256 constant MARKET_KIND = 4 << 248;

/// Creates the exchange's map, one slot wide and with home flags. Takers are long-tail accounts
/// that are never packed, and with a HOME hint for the taker a fully hinted settlement never
/// loads the directory. The flags cost one slot on the home page of each packed record.
/// @dev Intended for an immutable. Reverts if any record struct is wider than one slot.
function exchangeMap(string memory name) view returns (ExchangeMap) {
    PagedMap records = PagePack.mapWithHomeHints(name, 1);

    records.requireFits(_accountSlots());
    records.requireFits(_positionSlots());
    records.requireFits(_orderSlots());
    records.requireFits(_marketSlots());

    return ExchangeMap.wrap(PagedMap.unwrap(records));
}

// ----------------------------------------------------------------------------------------------
// Records
// ----------------------------------------------------------------------------------------------

// Each returns the record wherever it currently lives. Look it up again after anything that
// could rebalance.

function account(ExchangeMap records, address trader) view returns (Account storage record) {
    Record r = records.map().find(accountKey(trader));

    assembly ("memory-safe") {
        record.slot := r
    }
}

function position(ExchangeMap records, address trader, uint8 marketId)
    view
    returns (Position storage record)
{
    Record r = records.map().find(positionKey(trader, marketId));

    assembly ("memory-safe") {
        record.slot := r
    }
}

function order(ExchangeMap records, address trader, uint8 index)
    view
    returns (Order storage record)
{
    Record r = records.map().find(orderKey(trader, index));

    assembly ("memory-safe") {
        record.slot := r
    }
}

function market(ExchangeMap records, uint8 marketId) view returns (Market storage record) {
    Record r = records.map().find(marketKey(marketId));

    assembly ("memory-safe") {
        record.slot := r
    }
}

/// The underlying map, for hints and rebalancing.
function map(ExchangeMap records) pure returns (PagedMap) {
    return PagedMap.wrap(ExchangeMap.unwrap(records));
}

// ----------------------------------------------------------------------------------------------
// Keys
// ----------------------------------------------------------------------------------------------

// For hints, layouts and off-chain tools.

function accountKey(address trader) pure returns (bytes32) {
    return bytes32(ACCOUNT_KIND | uint160(trader));
}

function positionKey(address trader, uint8 marketId) pure returns (bytes32) {
    return bytes32(POSITION_KIND | (uint256(marketId) << 160) | uint160(trader));
}

function orderKey(address trader, uint8 index) pure returns (bytes32) {
    return bytes32(ORDER_KIND | (uint256(index) << 160) | uint160(trader));
}

function marketKey(uint8 marketId) pure returns (bytes32) {
    return bytes32(MARKET_KIND | marketId);
}

// ----------------------------------------------------------------------------------------------
// Sizes
// ----------------------------------------------------------------------------------------------

// A struct's size in slots is how far apart two of them sit in a storage array. These are `view`
// only because the compiler treats indexing a storage array as a possible read; nothing is read.

function _accountSlots() view returns (uint256 slots) {
    Account[2] storage pair;
    assembly ("memory-safe") {
        pair.slot := 0
    }

    Account storage second = pair[1];
    assembly ("memory-safe") {
        slots := second.slot
    }
}

function _positionSlots() view returns (uint256 slots) {
    Position[2] storage pair;
    assembly ("memory-safe") {
        pair.slot := 0
    }

    Position storage second = pair[1];
    assembly ("memory-safe") {
        slots := second.slot
    }
}

function _orderSlots() view returns (uint256 slots) {
    Order[2] storage pair;
    assembly ("memory-safe") {
        pair.slot := 0
    }

    Order storage second = pair[1];
    assembly ("memory-safe") {
        slots := second.slot
    }
}

function _marketSlots() view returns (uint256 slots) {
    Market[2] storage pair;
    assembly ("memory-safe") {
        pair.slot := 0
    }

    Market storage second = pair[1];
    assembly ("memory-safe") {
        slots := second.slot
    }
}
