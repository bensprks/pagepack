// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Entry, MapBuilder, PagePack, PagedMap} from "pagepack/PagePack.sol";

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

    /// Loads packed hints for the rest of the transaction.
    function useHints(bytes calldata hints) external {
        MAP.useHints(hints);
    }

    /// Loads packed hints, then looks `key` up without one, all in one call.
    function slotOfWithHints(bytes calldata hints, bytes32 key) external returns (uint256) {
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

/// A store that also reads whole entries. Kept apart so the benchmarks' store keeps its
/// bytecode, and so its gas.
abstract contract EntryReader is EntryStoreBase {
    constructor(PagedMap map_) EntryStoreBase(map_) {}

    /// Every data slot of the entry, found with `hint`.
    function readAll(bytes32 key, uint256 hint) external view returns (uint256[] memory data) {
        return _readAll(MAP.find(key, hint), MAP.sizeOf(key));
    }

    /// Every data slot of the entry, found after loading packed `hints`, all in one call.
    function readAllWithHints(bytes calldata hints, bytes32 key)
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

/// A map of one kind, `slots` wide, that also builds the hints a transaction carries and reads
/// them back. Kept apart for the same reason as EntryReader.
contract HintStore is EntryStoreBase {
    constructor(uint256 slots, bool homeHints) EntryStoreBase(_mapOfOneKind(slots, 0, homeHints)) {}

    function packedHintOf(bytes32 key) external view returns (bytes5) {
        return MAP.packedHintOf(key);
    }

    function packedHintsOf(bytes32[] calldata keys) external view returns (bytes memory) {
        return MAP.packedHintsOf(keys);
    }

    function hintsOf(bytes32[] calldata keys) external view returns (bytes memory) {
        return MAP.hintsOf(keys);
    }

    /// Loads the first `length` bytes of `hints`, then looks `key` up, all in one call.
    function slotOfWithHints(bytes calldata hints, uint256 length, bytes32 key)
        external
        returns (uint256)
    {
        MAP.useHints(hints[:length]);
        return MAP.find(key).slot();
    }

    /// Hint `i` of a run of 2-byte hints.
    function hintAt(bytes calldata hints, uint256 i) external pure returns (uint256) {
        return PagePack.hintAt(hints, i);
    }

    /// Hint `i` of the first `length` bytes of `hints`.
    function hintAt(bytes calldata hints, uint256 length, uint256 i)
        external
        pure
        returns (uint256)
    {
        return PagePack.hintAt(hints[:length], i);
    }

    /// Looks `key` up with hint `i` of a run of 2-byte hints.
    function slotOfAt(bytes32 key, bytes calldata hints, uint256 i)
        external
        view
        returns (uint256)
    {
        return MAP.find(key, PagePack.hintAt(hints, i)).slot();
    }
}

/// A map of one kind, `slots` wide, whose keys are any 32 bytes.
contract PlainEntryStore is EntryReader {
    /// @param perPage Entries per page, or 0 for the default.
    constructor(uint256 slots, uint256 perPage, bool homeHints)
        EntryReader(_mapOfOneKind(slots, perPage, homeHints))
    {}
}

/// A map of several kinds: kind `i` is `sizes[i]` slots wide, and a key's top byte names its
/// kind.
contract KindedEntryStore is EntryReader {
    /// @param perPage Entries per page, or 0 for the default.
    constructor(uint256[] memory sizes, uint256 perPage, bool homeHints)
        EntryReader(_mapOfKinds(sizes, perPage, homeHints))
    {}
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
    MapBuilder kinds = homeHints
        ? PagePack.mapOfKindsWithHomeHints("pagepack.test")
        : PagePack.mapOfKinds("pagepack.test");

    for (uint256 kind; kind < sizes.length; ++kind) {
        kinds = kinds.withKind(kind, sizes[kind]);
    }

    m = kinds.build();

    if (perPage != 0) m = m.withEntriesPerPage(perPage);
}
