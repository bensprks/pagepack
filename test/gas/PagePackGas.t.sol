// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PagePack, PagedMap} from "pagepack/PagePack.sol";
import {MappingBalances, PackedBalances} from "../utils/Balances.sol";

/// Measures updating N existing balances in one transaction. Each test is its own transaction,
/// so every page starts cold. Balances stay nonzero, so no state-growth charges are included:
/// the numbers isolate page I/O plus lookup overhead.
///
/// Layout: bench keys 0-63 fill one packed page, keys 64-93 are spread over three pages, keys 94+
/// are never packed, and 400 filler entries give the directory a realistic depth.
/// A second copy in a home-hint map measures HOME hints for the entries that aren't packed.
///
/// "Hinted" means 5-byte hints loaded once with useHints, the style the README shows. The hint
/// styles section measures the two ways of passing each lookup its hint instead. Every number is
/// a whole transaction's gas, so it includes the calldata that carries the keys and the hints.
contract PagePackGasTest is Test {
    uint256 internal constant FILLER = 400;
    uint256 internal constant ENTRIES_PER_PAGE = 64;

    MappingBalances internal mappingBalances;
    PackedBalances internal packedBalances;
    PackedBalances internal homeHintBalances;

    // Fingerprints taken in each map, so filler never clashes with an entry packed before it.
    mapping(uint256 fingerprint => bool) internal taken;
    mapping(uint256 fingerprint => bool) internal takenWithHomeHints;

    function setUp() public {
        mappingBalances = new MappingBalances();
        packedBalances = new PackedBalances(false);
        homeHintBalances = new PackedBalances(true);

        bytes32[] memory keys = new bytes32[](100);
        for (uint256 i; i < keys.length; ++i) {
            keys[i] = _key(i);
        }

        mappingBalances.seed(keys);
        packedBalances.seed(keys);
        homeHintBalances.seed(keys);

        PagePack.Placement[] memory placements = new PagePack.Placement[](94 + FILLER);

        for (uint256 i; i < ENTRIES_PER_PAGE; ++i) {
            placements[i] = PagePack.Placement(_key(i), i);
        }

        for (uint256 i; i < 30; ++i) {
            uint256 page = 4 + i / 10;
            placements[64 + i] = PagePack.Placement(_key(64 + i), page * ENTRIES_PER_PAGE + i % 10);
        }

        for (uint256 i; i < 94; ++i) {
            _take(placements[i].key);
        }

        uint256 next;
        for (uint256 i; i < FILLER; ++i) {
            while (!_take(_filler(next))) {
                ++next;
            }

            placements[94 + i] = PagePack.Placement(_filler(next++), 7 * ENTRIES_PER_PAGE + i);
        }

        packedBalances.pack(placements);
        homeHintBalances.pack(placements);
    }

    // ------------------------------------------------------------------------------------------
    // Entries packed onto one page
    // ------------------------------------------------------------------------------------------

    function test_gas_mapping_1() public {
        _bumpMapping("1 entry", 0, 1);
    }

    function test_gas_packed_1() public {
        _bumpPacked("1 entry", 0, 1);
    }

    function test_gas_hinted_1() public {
        _bumpHinted("1 entry", 0, 1);
    }

    function test_gas_mapping_2() public {
        _bumpMapping("2 entries", 0, 2);
    }

    function test_gas_packed_2() public {
        _bumpPacked("2 entries", 0, 2);
    }

    function test_gas_hinted_2() public {
        _bumpHinted("2 entries", 0, 2);
    }

    function test_gas_mapping_10() public {
        _bumpMapping("10 entries", 0, 10);
    }

    function test_gas_packed_10() public {
        _bumpPacked("10 entries", 0, 10);
    }

    function test_gas_hinted_10() public {
        _bumpHinted("10 entries", 0, 10);
    }

    function test_gas_mapping_30() public {
        _bumpMapping("30 entries", 0, 30);
    }

    function test_gas_packed_30() public {
        _bumpPacked("30 entries", 0, 30);
    }

    function test_gas_hinted_30() public {
        _bumpHinted("30 entries", 0, 30);
    }

    function test_gas_mapping_64() public {
        _bumpMapping("64 entries, a full page", 0, 64);
    }

    function test_gas_packed_64() public {
        _bumpPacked("64 entries, a full page", 0, 64);
    }

    function test_gas_hinted_64() public {
        _bumpHinted("64 entries, a full page", 0, 64);
    }

    // ------------------------------------------------------------------------------------------
    // Entries spread over three packed pages
    // ------------------------------------------------------------------------------------------

    function test_gas_mapping_30_3pages() public {
        _bumpMapping("30 entries, 3 pages", 64, 30);
    }

    function test_gas_packed_30_3pages() public {
        _bumpPacked("30 entries, 3 pages", 64, 30);
    }

    function test_gas_hinted_30_3pages() public {
        _bumpHinted("30 entries, 3 pages", 64, 30);
    }

    // ------------------------------------------------------------------------------------------
    // Entries that were never packed
    // ------------------------------------------------------------------------------------------

    function test_gas_mapping_unpacked_2() public {
        _bumpMapping("2 unpacked entries", 94, 2);
    }

    function test_gas_packed_unpacked_2() public {
        _bumpPacked("2 unpacked entries", 94, 2);
    }

    function test_gas_mapping_unpacked_home_2() public {
        _bumpMapping("2 unpacked entries, home-hint map", 94, 2);
    }

    function test_gas_packed_unpacked_home_2() public {
        _bumpPacked(homeHintBalances, "2 unpacked entries, home-hint map", 94, 2);
    }

    function test_gas_hinted_unpacked_home_2() public {
        _bumpHinted(homeHintBalances, "2 unpacked entries, home-hint map", 94, 2);
    }

    // ------------------------------------------------------------------------------------------
    // Hint styles: a hint passed to each lookup, as a word or as 2 bytes
    // ------------------------------------------------------------------------------------------

    function test_gas_hintWords_1() public {
        _bumpWithWords("1 entry", 1);
    }

    function test_gas_hintWords_10() public {
        _bumpWithWords("10 entries", 10);
    }

    function test_gas_hintWords_30() public {
        _bumpWithWords("30 entries", 30);
    }

    function test_gas_hintWords_64() public {
        _bumpWithWords("64 entries, a full page", 64);
    }

    function test_gas_hintBytes_1() public {
        _bumpPositional("1 entry", 1);
    }

    function test_gas_hintBytes_10() public {
        _bumpPositional("10 entries", 10);
    }

    function test_gas_hintBytes_30() public {
        _bumpPositional("30 entries", 30);
    }

    function test_gas_hintBytes_64() public {
        _bumpPositional("64 entries, a full page", 64);
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    function _bumpMapping(string memory scenario, uint256 first, uint256 count) internal {
        bytes32[] memory keys = _keys(first, count);

        mappingBalances.bump(keys);
        vm.snapshotGasLastCall("mapping", scenario);

        for (uint256 i; i < count; ++i) {
            assertEq(mappingBalances.balanceOf(keys[i]), 1_001);
        }
    }

    function _bumpPacked(string memory scenario, uint256 first, uint256 count) internal {
        _bumpPacked(packedBalances, scenario, first, count);
    }

    function _bumpPacked(
        PackedBalances target,
        string memory scenario,
        uint256 first,
        uint256 count
    ) internal {
        bytes32[] memory keys = _keys(first, count);

        target.bump(keys);
        vm.snapshotGasLastCall("pagepack", scenario);

        _assertBumped(target, keys);
    }

    function _bumpHinted(string memory scenario, uint256 first, uint256 count) internal {
        _bumpHinted(packedBalances, scenario, first, count);
    }

    function _bumpHinted(
        PackedBalances target,
        string memory scenario,
        uint256 first,
        uint256 count
    ) internal {
        bytes32[] memory keys = _keys(first, count);

        // One call builds the hints, as an offchain caller would. Every key has one.
        bytes memory hints = target.hintsFor(keys);
        assertEq(hints.length, 5 * count);

        // Reading hints above warmed the pages. Measure in a fresh transaction.
        vm.cool(address(target));

        target.bumpLoaded(keys, hints);
        vm.snapshotGasLastCall("pagepack-hinted", scenario);

        _assertBumped(target, keys);
    }

    /// The first `count` bench keys, each lookup passed its hint from a uint256[].
    function _bumpWithWords(string memory scenario, uint256 count) internal {
        bytes32[] memory keys = _keys(0, count);
        uint256[] memory hints = new uint256[](count);

        for (uint256 i; i < count; ++i) {
            hints[i] = packedBalances.hintOf(keys[i]);
            assertTrue(hints[i] != 0);
        }

        vm.cool(address(packedBalances));

        packedBalances.bump(keys, hints);
        vm.snapshotGasLastCall("pagepack-hinted-words", scenario);

        _assertBumped(packedBalances, keys);
    }

    /// The same, each hint read from 2 bytes at the key's position.
    function _bumpPositional(string memory scenario, uint256 count) internal {
        bytes32[] memory keys = _keys(0, count);
        bytes memory hints;

        for (uint256 i; i < count; ++i) {
            uint256 hint = packedBalances.hintOf(keys[i]);
            assertTrue(hint != 0);

            hints = bytes.concat(hints, bytes2(uint16(hint)));
        }

        vm.cool(address(packedBalances));

        packedBalances.bumpPositional(keys, hints);
        vm.snapshotGasLastCall("pagepack-hinted-positional", scenario);

        _assertBumped(packedBalances, keys);
    }

    function _assertBumped(PackedBalances target, bytes32[] memory keys) internal view {
        for (uint256 i; i < keys.length; ++i) {
            assertEq(target.balanceOf(keys[i]), 1_001);
        }
    }

    function _keys(uint256 first, uint256 count) internal pure returns (bytes32[] memory keys) {
        keys = new bytes32[](count);

        for (uint256 i; i < count; ++i) {
            keys[i] = _key(first + i);
        }
    }

    function _key(uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encode("bench", i));
    }

    /// Claims `key`'s fingerprint in both maps, unless either already has it.
    function _take(bytes32 key) internal returns (bool) {
        uint256 plain = PagePack.map("bench.balances", 1).fingerprintOf(key);
        uint256 hinted = PagePack.mapWithHomeHints("bench.balances", 1).fingerprintOf(key);
        if (taken[plain] || takenWithHomeHints[hinted]) return false;

        taken[plain] = true;
        takenWithHomeHints[hinted] = true;
        return true;
    }

    function _filler(uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encode("filler", i));
    }
}
