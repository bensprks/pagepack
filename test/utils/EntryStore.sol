// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PagePack, PagedMap} from "pagepack/PagePack.sol";

/// Exposes PagePack over a single map so tests can drive it through external calls.
contract EntryStore {
    PagedMap public immutable MAP;

    /// @param perPage Entries per page, or 0 for the default.
    constructor(uint256 slots, uint256 perPage, bool homeHints) {
        if (perPage == 0) {
            MAP = homeHints
                ? PagePack.mapWithHomeHints("pagepack.test", slots)
                : PagePack.map("pagepack.test", slots);
        } else {
            MAP = homeHints
                ? PagePack.mapWithHomeHints("pagepack.test", slots, perPage)
                : PagePack.map("pagepack.test", slots, perPage);
        }
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

    // Entries of another size than the map's own, through a view.

    function sized(uint256 slots) external view returns (PagedMap) {
        return MAP.sized(slots);
    }

    function get(bytes32 key, uint256 slots, uint256 offset, uint256 hint)
        external
        view
        returns (uint256)
    {
        return MAP.sized(slots).find(key, hint).read(offset);
    }

    function setSized(bytes32 key, uint256 slots, uint256 offset, uint256 value) external {
        MAP.sized(slots).find(key).write(offset, value);
    }

    function slotOfSized(bytes32 key, uint256 slots) external view returns (uint256) {
        return MAP.sized(slots).find(key).slot();
    }

    function slotOfSized(bytes32 key, uint256 slots, uint256 hint) external view returns (uint256) {
        return MAP.sized(slots).find(key, hint).slot();
    }

    /// Loads hints through the map, then looks `key` up at `slots` without one, in one call.
    function slotOfSizedWithHints(PagePack.Hint[] calldata hints, bytes32 key, uint256 slots)
        external
        returns (uint256)
    {
        MAP.useHints(hints);
        return MAP.sized(slots).find(key).slot();
    }

    function hintOfSized(bytes32 key, uint256 slots) external view returns (uint256) {
        return MAP.sized(slots).hintOf(key);
    }

    function fingerprintOfSized(bytes32 key, uint256 slots) external view returns (uint256) {
        return MAP.sized(slots).fingerprintOf(key);
    }
}
