// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PagePack} from "pagepack/PagePack.sol";
import {KindedEntryStore} from "../utils/EntryStore.sol";

/// Measures one request that makes room on several pages. Every page starts full, with 64
/// one-slot entries. On each page the request evicts 32 of them and packs 16 two-slot entries
/// from home. Evicted two by two, they leave gaps that fit. Evicted every other one, they leave
/// none, so each page compacts: its 32 staying entries slide together first. The difference
/// between the two is what compacting costs. Each measured call runs on cold storage.
abstract contract CompactionScaleGasTest is Test {
    KindedEntryStore internal store;
    bytes32[] internal narrow;
    bytes32[] internal wide;

    mapping(uint256 fingerprint => bool) internal seen;

    function pages() internal pure virtual returns (uint256);

    function label() internal pure virtual returns (string memory);

    function setUp() public {
        // Kinds of one and two slots, on pages of 64 tags and 64 data slots.
        uint256[] memory sizes = new uint256[](2);
        (sizes[0], sizes[1]) = (1, 2);
        store = new KindedEntryStore(sizes, 64, false);

        _addKeys(narrow, 0, 64 * pages());
        _addKeys(wide, 1, 16 * pages());

        PagePack.Placement[] memory placements = new PagePack.Placement[](narrow.length);

        for (uint256 i; i < narrow.length; ++i) {
            store.set(narrow[i], 0, i + 1);
            placements[i] = PagePack.Placement(narrow[i], i);
        }

        store.rebalance(placements);

        for (uint256 i; i < wide.length; ++i) {
            store.set(wide[i], 0, i + 1);
            store.set(wide[i], 1, i + 1);
        }
    }

    function test_gas_packIntoGaps() public {
        _rebalance(1);
        vm.snapshotGasLastCall("pagepack-rebalance-gaps", label());

        // Each two-slot entry takes the gap its index's old entry left.
        uint256 last = pages() - 1;
        assertEq(store.slotOf(wide[16 * last + 15]) & 127, 64 + 60);
        assertEq(store.slotOf(narrow[64 * last + 63]) & 127, 64 + 63);
        _assertEntries();
    }

    function test_gas_packByCompacting() public {
        _rebalance(2);
        vm.snapshotGasLastCall("pagepack-rebalance-compacting", label());

        // The 32 staying entries come first, then the 16 that arrived, in placement order.
        uint256 last = pages() - 1;
        assertEq(store.slotOf(narrow[64 * last + 1]) & 127, 64);
        assertEq(store.slotOf(narrow[64 * last + 63]) & 127, 64 + 31);
        assertEq(store.slotOf(wide[16 * last]) & 127, 64 + 32);
        assertEq(store.slotOf(wide[16 * last + 15]) & 127, 64 + 62);
        _assertEntries();
    }

    /// On every page and for the 16 values of j, evicts the entries at the page's indices 4j
    /// and 4j + `step`, and packs a two-slot entry at 4j: 48 placements a page.
    function _rebalance(uint256 step) internal {
        PagePack.Placement[] memory placements = new PagePack.Placement[](48 * pages());
        uint256 count;

        for (uint256 group; group < 16 * pages(); ++group) {
            placements[count++] = PagePack.Placement(narrow[4 * group], PagePack.HOME);
            placements[count++] = PagePack.Placement(narrow[4 * group + step], PagePack.HOME);
            placements[count++] = PagePack.Placement(wide[group], 4 * group);
        }

        // The setup above warmed the pages. Measure in a fresh transaction.
        vm.cool(address(store));
        store.rebalance(placements);
    }

    /// Every entry kept its data, and the packed ones their indices.
    function _assertEntries() internal view {
        assertEq(store.packedCount(), 48 * pages());

        for (uint256 i; i < narrow.length; ++i) {
            assertEq(store.get(narrow[i], 0), i + 1);
        }

        for (uint256 i; i < wide.length; ++i) {
            assertEq(store.hintOf(wide[i]), 4 * i + 1);
            assertEq(store.get(wide[i], 0), i + 1);
            assertEq(store.get(wide[i], 1), i + 1);
        }
    }

    /// Adds `count` keys of `kind`. Keys must have distinct fingerprints to be packed together.
    function _addKeys(bytes32[] storage keys, uint256 kind, uint256 count) internal {
        for (uint256 i; keys.length < count; ++i) {
            uint256 hash = uint256(keccak256(abi.encode("compaction.scale", kind, i)));
            bytes32 key = bytes32((kind << 248) | (hash >> 8));
            uint256 fingerprint = store.fingerprintOf(key);
            if (seen[fingerprint]) continue;

            seen[fingerprint] = true;
            keys.push(key);
        }
    }
}

contract CompactionScaleGas1Test is CompactionScaleGasTest {
    function pages() internal pure override returns (uint256) {
        return 1;
    }

    function label() internal pure override returns (string memory) {
        return "1 page";
    }
}

contract CompactionScaleGas8Test is CompactionScaleGasTest {
    function pages() internal pure override returns (uint256) {
        return 8;
    }

    function label() internal pure override returns (string memory) {
        return "8 pages";
    }
}
