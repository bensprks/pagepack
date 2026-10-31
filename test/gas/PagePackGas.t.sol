// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PagePack, Record, Space} from "pagepack/PagePack.sol";

/// Baseline: one Solidity mapping entry per balance.
contract MappingLedger {
    mapping(bytes32 key => uint256) public balanceOf;

    function seed(bytes32[] calldata keys) external {
        for (uint256 i; i < keys.length; ++i) {
            balanceOf[keys[i]] = 1_000;
        }
    }

    function bump(bytes32[] calldata keys) external {
        for (uint256 i; i < keys.length; ++i) {
            balanceOf[keys[i]] += 1;
        }
    }
}

/// The same ledger with balances stored as one-word PagePack records.
contract PackedLedger {
    Space internal immutable BALANCES = PagePack.space("bench.balances", 1);

    function balanceOf(bytes32 key) external view returns (uint256) {
        return BALANCES.find(key).read(0);
    }

    function hintOf(bytes32 key) external view returns (uint256) {
        return BALANCES.hintOf(key);
    }

    function seed(bytes32[] calldata keys) external {
        for (uint256 i; i < keys.length; ++i) {
            BALANCES.find(keys[i]).write(0, 1_000);
        }
    }

    function pack(PagePack.Placement[] calldata placements) external {
        BALANCES.rebalance(new bytes32[](0), placements);
    }

    function bump(bytes32[] calldata keys) external {
        for (uint256 i; i < keys.length; ++i) {
            Record r = BALANCES.find(keys[i]);
            r.write(0, r.read(0) + 1);
        }
    }

    function bump(bytes32[] calldata keys, uint256[] calldata hints) external {
        for (uint256 i; i < keys.length; ++i) {
            Record r = BALANCES.find(keys[i], hints[i]);
            r.write(0, r.read(0) + 1);
        }
    }
}

/// Measures updating N existing balances in one transaction. Each test is its own transaction,
/// so every page starts cold. Balances stay nonzero, so no state-growth charges are included:
/// the numbers isolate page I/O plus lookup overhead.
///
/// Layout: bench keys 0-29 sit together on one packed page, keys 30-59 are spread over three
/// pages, keys 60+ are never packed, and 400 filler records give the directory a realistic depth.
contract PagePackGasTest is Test {
    uint256 internal constant FILLER = 400;
    uint256 internal constant RECORDS_PER_PAGE = 64;

    MappingLedger internal mappingLedger;
    PackedLedger internal packedLedger;

    function setUp() public {
        mappingLedger = new MappingLedger();
        packedLedger = new PackedLedger();

        bytes32[] memory keys = new bytes32[](70);
        for (uint256 i; i < keys.length; ++i) {
            keys[i] = _key(i);
        }

        mappingLedger.seed(keys);
        packedLedger.seed(keys);

        PagePack.Placement[] memory placements = new PagePack.Placement[](60 + FILLER);

        for (uint256 i; i < 30; ++i) {
            placements[i] = PagePack.Placement(_key(i), i);
        }

        for (uint256 i; i < 30; ++i) {
            uint256 page = 4 + i / 10;
            placements[30 + i] = PagePack.Placement(_key(30 + i), page * RECORDS_PER_PAGE + i % 10);
        }

        for (uint256 i; i < FILLER; ++i) {
            placements[60 + i] = PagePack.Placement(_filler(i), 7 * RECORDS_PER_PAGE + i);
        }

        packedLedger.pack(placements);
    }

    // ------------------------------------------------------------------------------------------
    // Records packed onto one page
    // ------------------------------------------------------------------------------------------

    function test_gas_mapping_1() public {
        _bumpMapping("1 record", 0, 1);
    }

    function test_gas_packed_1() public {
        _bumpPacked("1 record", 0, 1);
    }

    function test_gas_hinted_1() public {
        _bumpHinted("1 record", 0, 1);
    }

    function test_gas_mapping_2() public {
        _bumpMapping("2 records", 0, 2);
    }

    function test_gas_packed_2() public {
        _bumpPacked("2 records", 0, 2);
    }

    function test_gas_hinted_2() public {
        _bumpHinted("2 records", 0, 2);
    }

    function test_gas_mapping_10() public {
        _bumpMapping("10 records", 0, 10);
    }

    function test_gas_packed_10() public {
        _bumpPacked("10 records", 0, 10);
    }

    function test_gas_hinted_10() public {
        _bumpHinted("10 records", 0, 10);
    }

    function test_gas_mapping_30() public {
        _bumpMapping("30 records", 0, 30);
    }

    function test_gas_packed_30() public {
        _bumpPacked("30 records", 0, 30);
    }

    function test_gas_hinted_30() public {
        _bumpHinted("30 records", 0, 30);
    }

    // ------------------------------------------------------------------------------------------
    // Records spread over three packed pages
    // ------------------------------------------------------------------------------------------

    function test_gas_mapping_30_3pages() public {
        _bumpMapping("30 records, 3 pages", 30, 30);
    }

    function test_gas_packed_30_3pages() public {
        _bumpPacked("30 records, 3 pages", 30, 30);
    }

    function test_gas_hinted_30_3pages() public {
        _bumpHinted("30 records, 3 pages", 30, 30);
    }

    // ------------------------------------------------------------------------------------------
    // Records that were never packed
    // ------------------------------------------------------------------------------------------

    function test_gas_mapping_unpacked_2() public {
        _bumpMapping("2 unpacked records", 60, 2);
    }

    function test_gas_packed_unpacked_2() public {
        _bumpPacked("2 unpacked records", 60, 2);
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    function _bumpMapping(string memory scenario, uint256 first, uint256 count) internal {
        bytes32[] memory keys = _keys(first, count);

        mappingLedger.bump(keys);
        vm.snapshotGasLastCall("mapping", scenario);

        for (uint256 i; i < count; ++i) {
            assertEq(mappingLedger.balanceOf(keys[i]), 1_001);
        }
    }

    function _bumpPacked(string memory scenario, uint256 first, uint256 count) internal {
        bytes32[] memory keys = _keys(first, count);

        packedLedger.bump(keys);
        vm.snapshotGasLastCall("pagepack", scenario);

        _assertBumped(keys);
    }

    function _bumpHinted(string memory scenario, uint256 first, uint256 count) internal {
        bytes32[] memory keys = _keys(first, count);
        uint256[] memory hints = new uint256[](count);

        for (uint256 i; i < count; ++i) {
            hints[i] = packedLedger.hintOf(keys[i]);
            assertTrue(hints[i] != 0);
        }

        // Reading hints above warmed the pages. Measure in a fresh transaction.
        vm.cool(address(packedLedger));

        packedLedger.bump(keys, hints);
        vm.snapshotGasLastCall("pagepack-hinted", scenario);

        _assertBumped(keys);
    }

    function _assertBumped(bytes32[] memory keys) internal view {
        for (uint256 i; i < keys.length; ++i) {
            assertEq(packedLedger.balanceOf(keys[i]), 1_001);
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

    function _filler(uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encode("filler", i));
    }
}
