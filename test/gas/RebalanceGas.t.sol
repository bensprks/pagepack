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
