// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PagePack} from "pagepack/PagePack.sol";
import {EntryStore} from "../utils/EntryStore.sol";

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
        placements[0] = PagePack.Placement(KEY, 0, index);

        store.rebalance(placements);
    }
}

/// Measures packing onto a full page of mixed sizes after two one-slot entries leave it, so its
/// two free slots are apart. Each test is its own transaction, so every page starts cold.
contract CompactionGasTest is Test {
    EntryStore internal store;

    function setUp() public {
        store = new EntryStore(1, 0, false);

        // 1 + 30 + 1 + 32 slots fill the page's 64 data slots, in that order.
        uint256[4] memory sizes = [uint256(1), 30, 1, 32];
        PagePack.Placement[] memory placements = new PagePack.Placement[](4);

        for (uint256 i; i < 4; ++i) {
            _fill(_key(i), sizes[i]);
            placements[i] = PagePack.Placement(_key(i), sizes[i], i);
        }

        store.rebalance(placements);

        placements = new PagePack.Placement[](2);
        placements[0] = PagePack.Placement(_key(0), 1, PagePack.HOME);
        placements[1] = PagePack.Placement(_key(2), 1, PagePack.HOME);
        store.rebalance(placements);

        _fill(_key(4), 1);
        _fill(_key(5), 2);
    }

    function test_gas_packIntoGap() public {
        store.rebalance(_place(_key(4), 1));
        vm.snapshotGasLastCall("pagepack-rebalance", "Pack a 1-slot entry into a gap");

        assertEq(store.hintOf(_key(4)), 5);
    }

    /// No gap fits two slots, so the 30- and 32-slot entries slide together first.
    function test_gas_packByCompacting() public {
        store.rebalance(_place(_key(5), 2));
        vm.snapshotGasLastCall("pagepack-rebalance", "Pack a 2-slot entry, moving 62 slots");

        assertEq(store.hintOfSized(_key(5), 2), (2 << 11) | 5);
        assertEq(store.get(_key(3), 32, 31, 0), 1);
    }

    function _fill(bytes32 key, uint256 slots) internal {
        for (uint256 i; i < slots; ++i) {
            store.setSized(key, slots, i, 1);
        }
    }

    function _place(bytes32 key, uint256 slots)
        internal
        pure
        returns (PagePack.Placement[] memory placements)
    {
        placements = new PagePack.Placement[](1);
        placements[0] = PagePack.Placement(key, slots, 4);
    }

    function _key(uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encode("compaction", i));
    }
}

/// Measures packing a two-slot entry onto a page of 64 one-slot entries after 32 of them leave
/// it, either two by two, which leaves gaps that fit, or every other one, which leaves none: the
/// 32 entries staying slide together first. Each measured call runs on cold storage.
contract NarrowCompactionGasTest is Test {
    bytes32 internal constant WIDE = keccak256("compaction.wide");

    EntryStore internal store;
    bytes32[] internal keys;
    mapping(uint256 fingerprint => bool) internal seen;

    function setUp() public {
        store = new EntryStore(1, 0, false);

        // Keys must have distinct fingerprints to be packed together.
        seen[store.fingerprintOfSized(WIDE, 2)] = true;

        for (uint256 i; keys.length < 64; ++i) {
            bytes32 key = keccak256(abi.encode("compaction.narrow", i));
            uint256 fingerprint = store.fingerprintOf(key);
            if (seen[fingerprint]) continue;

            seen[fingerprint] = true;
            keys.push(key);
        }

        PagePack.Placement[] memory placements = new PagePack.Placement[](64);

        for (uint256 i; i < 64; ++i) {
            store.set(keys[i], 0, 1);
            placements[i] = PagePack.Placement(keys[i], 0, i);
        }

        store.rebalance(placements);

        store.setSized(WIDE, 2, 0, 1);
        store.setSized(WIDE, 2, 1, 1);
    }

    function test_gas_packIntoGap() public {
        _evict(1);
        _packWide();
        vm.snapshotGasLastCall("pagepack-rebalance", "Pack a 2-slot entry into a gap");

        assertEq(store.hintOfSized(WIDE, 2), (2 << 11) | 1);
        assertEq(store.slotOfSized(WIDE, 2) & 127, 64);
        assertEq(store.slotOf(keys[2]) & 127, 66);
    }

    /// Every entry that stays sits one slot from the next, so all 32 move.
    function test_gas_packByCompacting() public {
        _evict(2);
        _packWide();
        vm.snapshotGasLastCall("pagepack-rebalance", "Pack a 2-slot entry, moving 32 entries");

        assertEq(store.hintOfSized(WIDE, 2), (2 << 11) | 1);
        assertEq(store.slotOfSized(WIDE, 2) & 127, 96);
        assertEq(store.slotOf(keys[1]) & 127, 64);
        assertEq(store.slotOf(keys[63]) & 127, 95);
        assertEq(store.get(keys[63], 0), 1);
    }

    /// Evicts entries 4j and 4j + `step`, for the 16 values of j: 32 in all.
    function _evict(uint256 step) internal {
        PagePack.Placement[] memory placements = new PagePack.Placement[](32);

        for (uint256 j; j < 16; ++j) {
            placements[2 * j] = PagePack.Placement(keys[4 * j], 0, PagePack.HOME);
            placements[2 * j + 1] = PagePack.Placement(keys[4 * j + step], 0, PagePack.HOME);
        }

        store.rebalance(placements);
    }

    function _packWide() internal {
        PagePack.Placement[] memory placements = new PagePack.Placement[](1);
        placements[0] = PagePack.Placement(WIDE, 2, 0);

        // The setup above warmed the pages. Measure in a fresh transaction.
        vm.cool(address(store));
        store.rebalance(placements);
    }
}
