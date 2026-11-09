// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PagePack} from "pagepack/PagePack.sol";
import {EntryStore, KindedEntryStore} from "../utils/EntryStore.sol";

/// Measures rebalancing moves. Each test is its own transaction, so every page starts cold.
contract RebalanceGasTest is Test {
    bytes32 internal constant KEY = keccak256("entry");

    EntryStore internal store;

    function setUp() public {
        // Three data slots and a tag each: 32 entries per page.
        store = new EntryStore(3, 0, false);

        for (uint256 i; i < 3; ++i) {
            store.set(KEY, i, 100 + i);
        }

        _place(0);
    }

    /// Moving between slots on one page should cost no state growth: every word that becomes
    /// occupied replaces one that was cleared on the same page.
    function test_gas_moveWithinPage() public {
        _place(1);
        vm.snapshotGasLastCall("pagepack-rebalance", "Move a 3-slot entry within a page");

        assertEq(store.hintOf(KEY), 2);

        for (uint256 i; i < 3; ++i) {
            assertEq(store.get(KEY, i), 100 + i);
        }
    }

    function _place(uint256 index) internal {
        PagePack.Placement[] memory placements = new PagePack.Placement[](1);
        placements[0] = PagePack.Placement(KEY, index);

        store.rebalance(placements);
    }
}

/// Measures packing onto a full page of mixed sizes after two one-slot entries leave it, so its
/// two free slots are apart. Each test is its own transaction, so every page starts cold.
contract CompactionGasTest is Test {
    KindedEntryStore internal store;

    // The kind of each key: kinds 0 to 3 are 1, 30, 32 and 2 slots.
    uint256[6] internal kinds = [uint256(0), 1, 0, 2, 0, 3];

    function setUp() public {
        // 64 tags and 64 data slots per page, as in a one-slot map.
        uint256[] memory sizes = new uint256[](4);
        (sizes[0], sizes[1], sizes[2], sizes[3]) = (1, 30, 32, 2);
        store = new KindedEntryStore(sizes, 64, false);

        // 1 + 30 + 1 + 32 slots fill the page's 64 data slots, in that order.
        PagePack.Placement[] memory placements = new PagePack.Placement[](4);

        for (uint256 i; i < 4; ++i) {
            _fill(_key(i));
            placements[i] = PagePack.Placement(_key(i), i);
        }

        store.rebalance(placements);

        placements = new PagePack.Placement[](2);
        placements[0] = PagePack.Placement(_key(0), PagePack.HOME);
        placements[1] = PagePack.Placement(_key(2), PagePack.HOME);
        store.rebalance(placements);

        _fill(_key(4));
        _fill(_key(5));
    }

    function test_gas_packIntoGap() public {
        store.rebalance(_place(_key(4)));
        vm.snapshotGasLastCall("pagepack-rebalance", "Pack a 1-slot entry into a gap");

        assertEq(store.hintOf(_key(4)), 5);
    }

    /// No gap fits two slots, so the 30- and 32-slot entries slide together first.
    function test_gas_packByCompacting() public {
        store.rebalance(_place(_key(5)));
        vm.snapshotGasLastCall("pagepack-rebalance", "Pack a 2-slot entry, moving 62 slots");

        assertEq(store.hintOf(_key(5)), 5);
        assertEq(store.get(_key(3), 31), 1);
    }

    function _fill(bytes32 key) internal {
        uint256 slots = store.sizeOf(key);

        for (uint256 i; i < slots; ++i) {
            store.set(key, i, 1);
        }
    }

    function _place(bytes32 key) internal pure returns (PagePack.Placement[] memory placements) {
        placements = new PagePack.Placement[](1);
        placements[0] = PagePack.Placement(key, 4);
    }

    function _key(uint256 i) internal view returns (bytes32) {
        return bytes32((kinds[i] << 248) | (uint256(keccak256(abi.encode("compaction", i))) >> 8));
    }
}
