// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Entry, PagePack, PagedMap} from "pagepack/PagePack.sol";

/// Exposes PagePack over a single map so tests can drive it through external calls.
abstract contract EntryStoreBase {
    PagedMap public immutable MAP;

    constructor(PagedMap map_) {
        MAP = map_;
    }

    function get(bytes32 key, uint256 offset) external view returns (uint256) {
        return MAP.find(key).read(offset);
    }

    function get(bytes32 key, uint256 offset, uint256 hint) external view returns (uint256) {
        return MAP.find(key, hint).read(offset);
    }

    function set(bytes32 key, uint256 offset, uint256 value) external {
        MAP.find(key).write(offset, value);
    }

    function slotOf(bytes32 key) external view returns (uint256) {
        return MAP.find(key).slot();
    }

    function slotOf(bytes32 key, uint256 hint) external view returns (uint256) {
        return MAP.find(key, hint).slot();
    }

    /// Loads hints for the rest of the transaction.
    function useHints(PagePack.Hint[] calldata hints) external {
        MAP.useHints(hints);
    }

    /// Loads hints, then looks `key` up without one, all in one call.
    function slotOfWithHints(PagePack.Hint[] calldata hints, bytes32 key)
        external
        returns (uint256)
    {
        MAP.useHints(hints);
        return MAP.find(key).slot();
    }

    function hintOf(bytes32 key) external view returns (uint256) {
        return MAP.hintOf(key);
    }

    function fingerprintOf(bytes32 key) external view returns (uint256) {
        return MAP.fingerprintOf(key);
    }

    function packedCount() external view returns (uint256) {
        return MAP.packedCount();
    }

    function entriesPerPage() external view returns (uint256) {
        return MAP.entriesPerPage();
    }

    function rebalance(PagePack.Placement[] memory placements) external {
        MAP.rebalance(placements);
    }

    function dataSlotsPerPage() external view returns (uint256) {
        return MAP.dataSlotsPerPage();
    }

    function sizeOf(bytes32 key) external view returns (uint256) {
        return MAP.sizeOf(key);
    }
}

/// A map of one kind, `slots` wide.
contract EntryStore is EntryStoreBase {
    /// @param perPage Entries per page, or 0 for the default.
    constructor(uint256 slots, uint256 perPage, bool homeHints)
        EntryStoreBase(_mapOfOneKind(slots, perPage, homeHints))
    {}
}

/// A map of several kinds: kind `i` is `sizes[i]` slots wide, and a key's top byte names its
/// kind. Kept apart so the benchmarks' store keeps its bytecode, and so its gas.
contract KindedEntryStore is EntryStoreBase {
    /// @param perPage Entries per page, or 0 for the default.
    constructor(uint256[] memory sizes, uint256 perPage, bool homeHints)
        EntryStoreBase(_mapOfKinds(sizes, perPage, homeHints))
    {}

    /// Every data slot of the entry, found with `hint`.
    function readAll(bytes32 key, uint256 hint) external view returns (uint256[] memory data) {
        return _readAll(MAP.find(key, hint), MAP.sizeOf(key));
    }

    /// Every data slot of the entry, found after loading `hints`, all in one call.
    function readAllWithHints(PagePack.Hint[] calldata hints, bytes32 key)
        external
        returns (uint256[] memory data)
    {
        MAP.useHints(hints);
        return _readAll(MAP.find(key), MAP.sizeOf(key));
    }

    function _readAll(Entry e, uint256 slots) internal view returns (uint256[] memory data) {
        data = new uint256[](slots);

        for (uint256 w; w < slots; ++w) {
            data[w] = e.read(w);
        }
    }
}

function _mapOfOneKind(uint256 slots, uint256 perPage, bool homeHints) pure returns (PagedMap m) {
    m = homeHints
        ? PagePack.mapWithHomeHints("pagepack.test", slots)
        : PagePack.map("pagepack.test", slots);

    if (perPage != 0) m = m.withEntriesPerPage(perPage);
}

function _mapOfKinds(uint256[] memory sizes, uint256 perPage, bool homeHints)
    pure
    returns (PagedMap m)
{
    m = homeHints
        ? PagePack.mapOfKindsWithHomeHints("pagepack.test")
        : PagePack.mapOfKinds("pagepack.test");

    for (uint256 kind; kind < sizes.length; ++kind) {
        m = m.withKind(kind, sizes[kind]);
    }

    if (perPage != 0) m = m.withEntriesPerPage(perPage);
}
