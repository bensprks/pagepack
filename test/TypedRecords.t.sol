// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PagePack, Record, Space} from "pagepack/PagePack.sol";

/// Typed access to records: a struct exactly as wide as its space, laid over a record's first
/// word, so Solidity handles the field offsets and packing.
contract TypedRecordsTest is Test {
    /// Three words: owner and frozen share word 0, debt fills word 1, and limit and updatedAt
    /// share word 2.
    struct Vault {
        address owner;
        bool frozen;
        uint256 debt;
        uint128 limit;
        uint64 updatedAt;
    }

    /// One word too many for the space.
    struct OverfullVault {
        Vault vault;
        uint256 extra;
    }

    Space internal immutable VAULTS = PagePack.space("test.vaults", 3);

    bytes32 internal constant KEY = "vault";

    function _vault(Record r) internal pure returns (Vault storage vault) {
        assembly ("memory-safe") {
            vault.slot := r
        }
    }

    function test_fieldsLandInTheRecordsWords() public {
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

    /// Copy this check for each struct: its last field lands in the record's last word only if
    /// the struct is exactly as wide as the space.
    function test_structMatchesTheSpaceWidth() public {
        Record r = VAULTS.find(KEY);
        _vault(r).updatedAt = 1;

        assertNotEq(r.read(VAULTS.width() - 1), 0);
    }

    /// What that check prevents: a wider struct over a packed record writes its last field into
    /// the next record's identity word, and the next record can no longer be found.
    function test_widerStructOverwritesTheNextRecord() public {
        bytes32 next = "next";
        _vault(VAULTS.find(next)).debt = 500;
        _pack(KEY, next);

        Record r = VAULTS.find(KEY);
        OverfullVault storage overfull;
        assembly ("memory-safe") {
            overfull.slot := r
        }
        overfull.extra = 1;

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

    /// Packs two records side by side, at indices 0 and 1.
    function _pack(bytes32 first, bytes32 second) internal {
        PagePack.Placement[] memory placements = new PagePack.Placement[](2);
        placements[0] = PagePack.Placement(first, 0);
        placements[1] = PagePack.Placement(second, 1);

        VAULTS.rebalance(new bytes32[](0), placements);
    }
}
