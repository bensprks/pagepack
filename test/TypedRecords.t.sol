// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PagePack, PagedMap, Record} from "pagepack/PagePack.sol";

/// Typed access to records: a struct exactly as wide as its map, laid over a record's first
/// slot, so Solidity handles the field offsets and packing.
contract TypedRecordsTest is Test {
    /// Three slots: owner and frozen share slot 0, debt fills slot 1, and limit and updatedAt
    /// share slot 2.
    struct Vault {
        address owner;
        bool frozen;
        uint256 debt;
        uint128 limit;
        uint64 updatedAt;
    }

    /// Four slots, one too many for the map. Its last field is an array that starts in the
    /// record's last slot and runs one slot past it.
    struct OverfullVault {
        address owner;
        uint256 debt;
        uint256[2] limits;
    }

    PagedMap internal immutable VAULTS = PagePack.map("test.vaults", 3);

    bytes32 internal constant KEY = "vault";

    function _vault(Record r) internal pure returns (Vault storage vault) {
        assembly ("memory-safe") {
            vault.slot := r
        }
    }

    function _overfullVault(Record r) internal pure returns (OverfullVault storage vault) {
        assembly ("memory-safe") {
            vault.slot := r
        }
    }

    function test_fieldsLandInTheRecordsSlots() public {
        Record r = VAULTS.find(KEY);
        Vault storage vault = _vault(r);

        vault.owner = address(0xBEEF);
        vault.frozen = true;
        vault.debt = 500;
        vault.limit = 1_000;
        vault.updatedAt = 7;

        assertEq(r.read(0), uint256(uint160(address(0xBEEF))) | (1 << 160));
        assertEq(r.read(1), 500);
        assertEq(r.read(2), 1_000 | (7 << 128));
    }

    /// Copy this check for each struct: it must be exactly as wide as its map.
    function test_structMatchesTheMapWidth() public view {
        assertEq(_vaultSlots(), VAULTS.width());
    }

    /// The check counts every slot a struct takes, arrays and nested structs included.
    function test_widthCheckCatchesAWiderStruct() public view {
        assertEq(_overfullVaultSlots(), VAULTS.width() + 1);
    }

    /// The check's helpers must be `view`, not `pure`, yet they never touch storage.
    function test_widthCheckTouchesNoStorage() public {
        vm.record();
        uint256 slots = _vaultSlots();
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(this));

        assertEq(slots, 3);
        assertEq(reads.length, 0);
        assertEq(writes.length, 0);
    }

    /// What the check prevents: a wider struct over a packed record writes into the next record's
    /// identity word, and the next record can no longer be found.
    function test_widerStructOverwritesTheNextRecord() public {
        bytes32 next = "next";
        _vault(VAULTS.find(next)).debt = 500;
        _pack(KEY, next);

        Record r = VAULTS.find(KEY);
        _overfullVault(r).limits = [uint256(1), uint256(1)];

        // The record's last slot is set, as if the struct fit, so checking that slot alone
        // would miss the overflow.
        assertNotEq(r.read(VAULTS.width() - 1), 0);
        assertEq(_vault(VAULTS.find(next)).debt, 0);
    }

    /// A struct pointer is only as current as the lookup it came from.
    function test_structPointerGoesStaleWhenTheRecordMoves() public {
        Vault storage vault = _vault(VAULTS.find(KEY));
        vault.debt = 500;

        _pack(KEY, "other");

        // The old pointer still names the record's home, which packing cleared.
        assertEq(vault.debt, 0);
        assertEq(_vault(VAULTS.find(KEY)).debt, 500);
    }

    // A struct's size in slots is how far apart two of them sit in a storage array. These helpers
    // are `view` only because the compiler treats indexing a storage array as a possible read and
    // rejects `pure`. Indexing a fixed-size array just computes a slot, so they read and write no
    // storage.

    function _vaultSlots() internal view returns (uint256 slots) {
        Vault[2] storage pair;
        assembly ("memory-safe") {
            pair.slot := 0
        }

        Vault storage second = pair[1];
        assembly ("memory-safe") {
            slots := second.slot
        }
    }

    function _overfullVaultSlots() internal view returns (uint256 slots) {
        OverfullVault[2] storage pair;
        assembly ("memory-safe") {
            pair.slot := 0
        }

        OverfullVault storage second = pair[1];
        assembly ("memory-safe") {
            slots := second.slot
        }
    }

    /// Packs two records side by side, at indices 0 and 1.
    function _pack(bytes32 first, bytes32 second) internal {
        PagePack.Placement[] memory placements = new PagePack.Placement[](2);
        placements[0] = PagePack.Placement(first, 0);
        placements[1] = PagePack.Placement(second, 1);

        VAULTS.rebalance(new bytes32[](0), placements);
    }
}
