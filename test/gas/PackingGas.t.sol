// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PagePack} from "pagepack/PagePack.sol";
import {RecordStore} from "../utils/RecordStore.sol";

/// Measures packing 16 records from home in one call, by record shape. Each space already lists
/// 32 records, so the directory exists; the 16 new ones fill fresh pages. Each test is its own
/// transaction, so every page starts cold.
contract PackingGasTest is Test {
    uint256 internal constant EXISTING = 32;
    uint256 internal constant NEW = 16;

    RecordStore internal oneWord;
    RecordStore internal threeWords;
    RecordStore internal eightWords;
    RecordStore internal eightWordsSparse;
    RecordStore internal neverWritten;
    RecordStore internal oneWordHomeHints;
    RecordStore internal neverWrittenHomeHints;

    function setUp() public {
        oneWord = _prepare(1, 1, false);
        threeWords = _prepare(3, 3, false);
        eightWords = _prepare(8, 8, false);
        eightWordsSparse = _prepare(8, 1, false);
        neverWritten = _prepare(1, 0, false);
        oneWordHomeHints = _prepare(1, 1, true);
        neverWrittenHomeHints = _prepare(1, 0, true);
    }

    function test_gas_pack_oneWord() public {
        _pack(oneWord, "1-word records");
    }

    function test_gas_pack_threeWords() public {
        _pack(threeWords, "3-word records");
    }

    function test_gas_pack_eightWords() public {
        _pack(eightWords, "8-word records");
    }

    function test_gas_pack_eightWordsSparse() public {
        _pack(eightWordsSparse, "8-word records, 1 word set");
    }

    function test_gas_pack_neverWritten() public {
        _pack(neverWritten, "1-word records, never written");
    }

    function test_gas_pack_oneWordHomeHints() public {
        _pack(oneWordHomeHints, "1-word records, home-hint space");
    }

    function test_gas_pack_neverWrittenHomeHints() public {
        _pack(neverWrittenHomeHints, "1-word records, never written, home-hint space");
    }

    /// A store whose records are `words` wide with the first `set` words written, and the first
    /// EXISTING of them already packed.
    function _prepare(uint256 words, uint256 set, bool homeHints)
        internal
        returns (RecordStore store)
    {
        store = new RecordStore(words, homeHints);

        for (uint256 i; i < EXISTING + NEW; ++i) {
            for (uint256 w; w < set; ++w) {
                store.set(_key(i), w, 100 + w);
            }
        }

        store.rebalance(new bytes32[](0), _placements(0, EXISTING));
    }

    function _pack(RecordStore store, string memory shape) internal {
        // Start the new records on a fresh page.
        uint256 perPage = store.recordsPerPage();
        uint256 first = (EXISTING + perPage - 1) / perPage * perPage;

        PagePack.Placement[] memory placements = _placements(EXISTING, NEW);
        for (uint256 i; i < NEW; ++i) {
            placements[i].index = first + i;
        }

        store.rebalance(new bytes32[](0), placements);
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
            placements[i] = PagePack.Placement(_key(from + i), from + i);
        }
    }

    function _key(uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encode("packing", i));
    }
}
