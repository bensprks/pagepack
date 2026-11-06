// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Entry, PagePack} from "pagepack/PagePack.sol";
import {Balance, BalanceMap, balanceKey, balanceMap} from "../../examples/orderbook/BalanceMap.sol";

/// The typed map example: traders' Balances looked up by address in a map as wide as the struct.
contract BalanceMapTest is Test {
    BalanceMap internal immutable BALANCES = balanceMap("test.balances");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function test_widthComesFromTheStruct() public view {
        assertEq(BALANCES.map().width(), 1);
        assertEq(BALANCES.map().entriesPerPage(), 64);
    }

    function test_fieldsLandInTheAccountsEntry() public {
        Balance storage balance = BALANCES.find(alice);
        balance.base = 7;
        balance.quote = 1_000;

        Entry e = BALANCES.map().find(balanceKey(alice));
        assertEq(e.read(0), 7 | (1_000 << 128));
    }

    function test_addressIsTheKey() public view {
        assertEq(balanceKey(alice), bytes32(uint256(uint160(alice))));
    }

    function test_balancesMoveWithRebalancing() public {
        BALANCES.find(alice).quote = 100;
        BALANCES.find(bob).quote = 200;

        _pack(alice, bob);

        // Packed side by side after the page's tags, one data slot each.
        assertEq(_slot(bob), _slot(alice) + 1);
        assertEq(BALANCES.map().hintOf(balanceKey(bob)), 2);

        BALANCES.find(bob).base += 1;

        assertEq(BALANCES.find(alice).quote, 100);
        assertEq(BALANCES.find(bob).quote, 200);
        assertEq(BALANCES.find(bob).base, 1);
    }

    /// A hint loaded on the underlying map serves the typed lookup, which then skips the
    /// directory.
    function test_typedLookupsUseHints() public {
        BALANCES.find(alice).quote = 100;
        _pack(alice, bob);

        BALANCES.map().useHint(balanceKey(alice), 1);
        address account = alice;

        vm.record();
        assertEq(BALANCES.find(account).quote, 100);
        (bytes32[] memory reads,) = vm.accesses(address(this));

        // The tag, then the data.
        assertEq(reads.length, 2);
    }

    function _pack(address first, address second) internal {
        PagePack.Placement[] memory placements = new PagePack.Placement[](2);
        placements[0] = PagePack.Placement(balanceKey(first), 0);
        placements[1] = PagePack.Placement(balanceKey(second), 1);

        BALANCES.map().rebalance(new bytes32[](0), placements);
    }

    function _slot(address account) internal view returns (uint256) {
        return BALANCES.map().find(balanceKey(account)).slot();
    }
}
