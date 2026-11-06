// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PagePack} from "pagepack/PagePack.sol";
import {EntryStore} from "../utils/EntryStore.sol";

/// Measures packing 16 entries from home in one call, by entry shape. Each map already lists
/// 32 entries, so the directory exists; the 16 new ones fill fresh pages. Each test is its own
/// transaction, so every page starts cold.
contract PackingGasTest is Test {
    uint256 internal constant EXISTING = 32;
    uint256 internal constant NEW = 16;

    EntryStore internal oneSlot;
    EntryStore internal threeSlots;
    EntryStore internal eightSlots;
    EntryStore internal eightSlotsSparse;
    EntryStore internal neverWritten;
    EntryStore internal oneSlotHomeHints;
    EntryStore internal neverWrittenHomeHints;

    function setUp() public {
        oneSlot = _prepare(1, 1, false);
        threeSlots = _prepare(3, 3, false);
        eightSlots = _prepare(8, 8, false);
        eightSlotsSparse = _prepare(8, 1, false);
        neverWritten = _prepare(1, 0, false);
        oneSlotHomeHints = _prepare(1, 1, true);
        neverWrittenHomeHints = _prepare(1, 0, true);
    }

    function test_gas_pack_oneSlot() public {
        _pack(oneSlot, "1-slot entries");
    }

    function test_gas_pack_threeSlots() public {
        _pack(threeSlots, "3-slot entries");
    }

    function test_gas_pack_eightSlots() public {
        _pack(eightSlots, "8-slot entries");
    }

    function test_gas_pack_eightSlotsSparse() public {
        _pack(eightSlotsSparse, "8-slot entries, 1 slot set");
    }

    function test_gas_pack_neverWritten() public {
        _pack(neverWritten, "1-slot entries, never written");
    }

    function test_gas_pack_oneSlotHomeHints() public {
        _pack(oneSlotHomeHints, "1-slot entries, home-hint map");
    }

    function test_gas_pack_neverWrittenHomeHints() public {
        _pack(neverWrittenHomeHints, "1-slot entries, never written, home-hint map");
    }

    /// A store whose entries are `slots` wide with the first `set` slots written, and the first
    /// EXISTING of them already packed.
    function _prepare(uint256 slots, uint256 set, bool homeHints)
        internal
        returns (EntryStore store)
    {
        store = new EntryStore(slots, homeHints);

        for (uint256 i; i < EXISTING + NEW; ++i) {
            for (uint256 w; w < set; ++w) {
                store.set(_key(i), w, 100 + w);
            }
        }

        store.rebalance(_placements(0, EXISTING));
    }

    function _pack(EntryStore store, string memory shape) internal {
        // Start the new entries on a fresh page.
        uint256 perPage = store.entriesPerPage();
        uint256 first = (EXISTING + perPage - 1) / perPage * perPage;

        PagePack.Placement[] memory placements = _placements(EXISTING, NEW);
        for (uint256 i; i < NEW; ++i) {
            placements[i].index = first + i;
        }

        store.rebalance(placements);
        vm.snapshotGasLastCall("pagepack-packing", shape);

        assertEq(store.packedCount(), EXISTING + NEW);
        assertEq(store.hintOf(_key(EXISTING)), first + 1);
    }

    function _placements(uint256 from, uint256 count)
        internal
        pure
        returns (PagePack.Placement[] memory placements)
    {
        placements = new PagePack.Placement[](count);

        for (uint256 i; i < count; ++i) {
            placements[i] = PagePack.Placement(_key(from + i), 0, from + i);
        }
    }

    function _key(uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encode("packing", i));
    }
}
