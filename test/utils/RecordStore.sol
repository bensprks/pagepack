// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PagePack, Space} from "pagepack/PagePack.sol";

/// Exposes PagePack over a single space so tests can drive it through external calls.
contract RecordStore {
    Space public immutable SPACE;

    constructor(uint256 words, bool homeHints) {
        SPACE = homeHints
            ? PagePack.spaceWithHomeHints("pagepack.test", words)
            : PagePack.space("pagepack.test", words);
    }

    function get(bytes32 key, uint256 offset) external view returns (uint256) {
        return SPACE.find(key).read(offset);
    }

    function get(bytes32 key, uint256 offset, uint256 hint) external view returns (uint256) {
        return SPACE.find(key, hint).read(offset);
    }

    function set(bytes32 key, uint256 offset, uint256 value) external {
        SPACE.find(key).write(offset, value);
    }

    function slotOf(bytes32 key) external view returns (uint256) {
        return SPACE.find(key).slot();
    }

    function slotOf(bytes32 key, uint256 hint) external view returns (uint256) {
        return SPACE.find(key, hint).slot();
    }

    /// Loads hints for the rest of the transaction.
    function useHints(PagePack.Hint[] calldata hints) external {
        SPACE.useHints(hints);
    }

    /// Loads hints, then looks `key` up without one, all in one call.
    function slotOfWithHints(PagePack.Hint[] calldata hints, bytes32 key)
        external
        returns (uint256)
    {
        SPACE.useHints(hints);
        return SPACE.find(key).slot();
    }

    function hintOf(bytes32 key) external view returns (uint256) {
        return SPACE.hintOf(key);
    }

    function fingerprintOf(bytes32 key) external view returns (uint256) {
        return SPACE.fingerprintOf(key);
    }

    function packedCount() external view returns (uint256) {
        return SPACE.packedCount();
    }

    function recordsPerPage() external view returns (uint256) {
        return SPACE.recordsPerPage();
    }

    function rebalance(bytes32[] memory evictions, PagePack.Placement[] memory placements)
        external
    {
        SPACE.rebalance(evictions, placements);
    }
}
