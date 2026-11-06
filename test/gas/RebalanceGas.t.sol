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
        store = new EntryStore(3, false);

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
