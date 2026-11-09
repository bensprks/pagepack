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

/// Measures packing a two-slot entry onto a page of 64 one-slot entries after 32 of them leave
/// it, either two by two, which leaves gaps that fit, or every other one, which leaves none: the
/// 32 entries staying slide together first. Each measured call runs on cold storage.
contract NarrowCompactionGasTest is Test {
    // Kind 1, two slots.
    bytes32 internal constant WIDE = bytes32((uint256(1) << 248) | 1);

    KindedEntryStore internal store;
    bytes32[] internal keys;
    mapping(uint256 fingerprint => bool) internal seen;

    function setUp() public {
        // Kinds of one and two slots, on pages of 64 tags and 64 data slots.
        uint256[] memory sizes = new uint256[](2);
        (sizes[0], sizes[1]) = (1, 2);
        store = new KindedEntryStore(sizes, 64, false);

        // Keys must have distinct fingerprints to be packed together.
        seen[store.fingerprintOf(WIDE)] = true;

        for (uint256 i; keys.length < 64; ++i) {
            // Kind 0, one slot.
            bytes32 key = bytes32(uint256(keccak256(abi.encode("compaction.narrow", i))) >> 8);
            uint256 fingerprint = store.fingerprintOf(key);
            if (seen[fingerprint]) continue;

            seen[fingerprint] = true;
            keys.push(key);
        }

        PagePack.Placement[] memory placements = new PagePack.Placement[](64);

        for (uint256 i; i < 64; ++i) {
            store.set(keys[i], 0, 1);
            placements[i] = PagePack.Placement(keys[i], i);
        }

        store.rebalance(placements);

        store.set(WIDE, 0, 1);
        store.set(WIDE, 1, 1);
    }

    function test_gas_packIntoGap() public {
        _evict(1);
        _packWide();
        vm.snapshotGasLastCall("pagepack-rebalance", "Pack a 2-slot entry into a gap");

        assertEq(store.hintOf(WIDE), 1);
        assertEq(store.slotOf(WIDE) & 127, 64);
        assertEq(store.slotOf(keys[2]) & 127, 66);
    }

    /// Every entry that stays sits one slot from the next, so all 32 move.
    function test_gas_packByCompacting() public {
        _evict(2);
        _packWide();
        vm.snapshotGasLastCall("pagepack-rebalance", "Pack a 2-slot entry, moving 32 entries");

        assertEq(store.hintOf(WIDE), 1);
        assertEq(store.slotOf(WIDE) & 127, 96);
        assertEq(store.slotOf(keys[1]) & 127, 64);
        assertEq(store.slotOf(keys[63]) & 127, 95);
        assertEq(store.get(keys[63], 0), 1);
    }

    /// Evicts entries 4j and 4j + `step`, for the 16 values of j: 32 in all.
    function _evict(uint256 step) internal {
        PagePack.Placement[] memory placements = new PagePack.Placement[](32);

        for (uint256 j; j < 16; ++j) {
            placements[2 * j] = PagePack.Placement(keys[4 * j], PagePack.HOME);
            placements[2 * j + 1] = PagePack.Placement(keys[4 * j + step], PagePack.HOME);
        }

        store.rebalance(placements);
    }

    function _packWide() internal {
        PagePack.Placement[] memory placements = new PagePack.Placement[](1);
        placements[0] = PagePack.Placement(WIDE, 0);

        // The setup above warmed the pages. Measure in a fresh transaction.
        vm.cool(address(store));
        store.rebalance(placements);
    }
}
