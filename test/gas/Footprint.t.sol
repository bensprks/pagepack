// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PagePack} from "pagepack/PagePack.sol";
import {LibSort} from "pagepack/utils/LibSort.sol";
import {MappingBalances, PackedBalances} from "../utils/Balances.sol";

/// Counts the storage each layout leaves behind for 512 nonzero one-slot balances: live slots,
/// and the pages they occupy. These are logical counts of nonzero slots, not node database bytes.
contract FootprintTest is Test {
    uint256 internal constant ENTRIES = 512;

    function test_footprint_mapping() public {
        MappingBalances balances = new MappingBalances();

        vm.record();
        balances.seed(_keys());

        _snapshot("Mapping", address(balances));
    }

    function test_footprint_unpacked() public {
        PackedBalances balances = new PackedBalances(false);

        vm.record();
        balances.seed(_keys());

        _snapshot("pagepack, nothing packed", address(balances));
    }

    function test_footprint_packed() public {
        PackedBalances balances = new PackedBalances(false);

        vm.record();
        balances.seed(_keys());
        balances.pack(_layout());

        _snapshot("pagepack, all packed", address(balances));
    }

    function test_footprint_packedWithHomeHints() public {
        PackedBalances balances = new PackedBalances(true);

        vm.record();
        balances.seed(_keys());
        balances.pack(_layout());

        _snapshot("pagepack with home hints, all packed", address(balances));
    }

    /// Every slot the contract wrote since vm.record(), keeping the ones still nonzero.
    function _snapshot(string memory layout, address target) internal {
        (, bytes32[] memory writes) = vm.accesses(target);

        uint256[] memory slots = new uint256[](writes.length);
        for (uint256 i; i < writes.length; ++i) {
            slots[i] = uint256(writes[i]);
        }
        LibSort.sort(slots);

        uint256 live;
        uint256 pages;
        uint256 lastSlot = type(uint256).max;
        uint256 lastPage = type(uint256).max;

        for (uint256 i; i < slots.length; ++i) {
            uint256 slot = slots[i];
            if (slot == lastSlot) continue;
            lastSlot = slot;

            if (vm.load(target, bytes32(slot)) == 0) continue;
            ++live;

            // Sorted slots keep each page's slots together.
            if (slot >> 7 != lastPage) {
                lastPage = slot >> 7;
                ++pages;
            }
        }

        vm.snapshotValue("footprint-slots", layout, live);
        vm.snapshotValue("footprint-pages", layout, pages);
    }

    function _keys() internal pure returns (bytes32[] memory keys) {
        keys = new bytes32[](ENTRIES);

        for (uint256 i; i < ENTRIES; ++i) {
            keys[i] = keccak256(abi.encode("footprint", i));
        }
    }

    /// Packed back to back from index 0: eight full pages of 64.
    function _layout() internal pure returns (PagePack.Placement[] memory placements) {
        bytes32[] memory keys = _keys();
        placements = new PagePack.Placement[](ENTRIES);

        for (uint256 i; i < ENTRIES; ++i) {
            placements[i] = PagePack.Placement(keys[i], i);
        }
    }
}
