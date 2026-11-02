// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Entry, PagePack} from "pagepack/PagePack.sol";
import {Loan, LoanMap, loanKey, loanMap} from "../../examples/loans/LoanMap.sol";

/// The typed map example: Loans looked up by id in a map as wide as the struct.
contract LoanMapTest is Test {
    LoanMap internal immutable LOANS = loanMap("test.loans");

    function test_widthComesFromTheStruct() public view {
        assertEq(LOANS.map().width(), 2);
        assertEq(LOANS.map().entriesPerPage(), 42);
    }

    function test_fieldsLandInTheLoansEntry() public {
        Loan storage loan = LOANS.find(7);
        loan.borrower = address(0xBEEF);
        loan.openedAt = 100;
        loan.rateBps = 500;
        loan.principal = 1_000;
        loan.interest = 3;

        Entry e = LOANS.map().find(loanKey(7));
        assertEq(e.read(0), uint256(uint160(address(0xBEEF))) | (100 << 160) | (500 << 224));
        assertEq(e.read(1), 1_000 | (3 << 128));
    }

    function test_loanIdIsTheKey() public pure {
        assertEq(loanKey(7), bytes32(uint256(7)));
    }

    function test_loansMoveWithRebalancing() public {
        LOANS.find(1).principal = 100;
        LOANS.find(2).principal = 200;

        _pack(1, 2);

        // Packed side by side: each entry is an identity word plus two data slots.
        assertEq(_slot(2), _slot(1) + 3);
        assertEq(LOANS.map().hintOf(loanKey(2)), 2);

        LOANS.find(2).interest += 1;

        assertEq(LOANS.find(1).principal, 100);
        assertEq(LOANS.find(2).principal, 200);
        assertEq(LOANS.find(2).interest, 1);
    }

    /// A hint loaded on the underlying map serves the typed lookup, which then skips the
    /// directory.
    function test_typedLookupsUseHints() public {
        LOANS.find(1).principal = 100;
        _pack(1, 2);

        LOANS.map().useHint(loanKey(1), 1);

        vm.record();
        assertEq(LOANS.find(1).principal, 100);
        (bytes32[] memory reads,) = vm.accesses(address(this));

        // The identity word, then the data.
        assertEq(reads.length, 2);
    }

    function _pack(uint256 first, uint256 second) internal {
        PagePack.Placement[] memory placements = new PagePack.Placement[](2);
        placements[0] = PagePack.Placement(loanKey(first), 0);
        placements[1] = PagePack.Placement(loanKey(second), 1);

        LOANS.map().rebalance(new bytes32[](0), placements);
    }

    function _slot(uint256 loanId) internal view returns (uint256) {
        return LOANS.map().find(loanKey(loanId)).slot();
    }
}
