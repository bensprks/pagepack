// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PagePack, PagedMap} from "pagepack/PagePack.sol";
import {
    AccountMap,
    accountKey,
    accountMap,
    accountPlacement,
    accountSlots,
    approvalKey,
    approvalPlacement,
    approvalSlots
} from "../../examples/accounts/AccountMap.sol";

/// Loads hints in one call and spends in another, as a contract would within one transaction.
contract Spender {
    AccountMap internal immutable ACCOUNTS = accountMap("test.accounts");

    function spend(address owner, uint128 amount, PagePack.Hint[] calldata hints) external {
        ACCOUNTS.map().useHints(hints);

        ACCOUNTS.approval(owner, msg.sender).amount -= amount;
        ACCOUNTS.account(owner).balance -= amount;
    }

    function fund(address owner, uint256 balance, uint128 allowed) external {
        ACCOUNTS.account(owner).balance = balance;
        ACCOUNTS.approval(owner, msg.sender).amount = allowed;
    }

    function pack(PagePack.Placement[] calldata placements) external {
        ACCOUNTS.map().rebalance(placements);
    }

    function accountHint(address owner) external view returns (PagePack.Hint memory) {
        return ACCOUNTS.accountHint(owner);
    }

    function approvalHint(address owner, address spender)
        external
        view
        returns (PagePack.Hint memory)
    {
        return ACCOUNTS.approvalHint(owner, spender);
    }

    function slotOf(bytes32 key, uint256 slots) external view returns (uint256) {
        return ACCOUNTS.map().sized(slots).find(key).slot();
    }

    function balanceOf(address owner) external view returns (uint256) {
        return ACCOUNTS.account(owner).balance;
    }

    function allowance(address owner, address spender) external view returns (uint128) {
        return ACCOUNTS.approval(owner, spender).amount;
    }
}

/// The typed map example of two sizes: two-slot accounts and one-slot approvals in one map.
contract AccountMapTest is Test {
    Spender internal spender;

    function setUp() public {
        spender = new Spender();
    }

    function test_kindsHaveTheirStructsSizes() public view {
        PagedMap m = accountMap("test.accounts").map();

        assertEq(accountSlots(), 2);
        assertEq(approvalSlots(), 1);
        assertEq(m.width(), 1);
        assertEq(m.entriesPerPage(), 50);
        assertEq(m.dataSlotsPerPage(), 78);
    }

    /// 25 owners' accounts and approvals fill one page's 50 tags and 75 of its 78 data slots.
    function test_accountsAndApprovalsShareAPage() public {
        address[] memory owners = _owners(25);
        PagePack.Placement[] memory placements = new PagePack.Placement[](50);

        for (uint256 i; i < owners.length; ++i) {
            vm.prank(owners[i]);
            spender.fund(owners[i], 1_000 + i, uint128(100 + i));

            placements[2 * i] = accountPlacement(owners[i], 2 * i);
            placements[2 * i + 1] = approvalPlacement(owners[i], owners[i], 2 * i + 1);
        }

        spender.pack(placements);

        uint256 page = spender.slotOf(accountKey(owners[0]), 2) >> 7;

        for (uint256 i; i < owners.length; ++i) {
            assertEq(spender.slotOf(accountKey(owners[i]), 2) >> 7, page);
            assertEq(spender.slotOf(approvalKey(owners[i], owners[i]), 1) >> 7, page);
            assertEq(spender.balanceOf(owners[i]), 1_000 + i);
            assertEq(spender.allowance(owners[i], owners[i]), 100 + i);
        }
    }

    /// One list of hints covers both kinds.
    function test_oneHintListServesBothKinds() public {
        address owner = makeAddr("owner");
        address other = makeAddr("other");

        vm.prank(other);
        spender.fund(owner, 1_000, 300);

        PagePack.Placement[] memory placements = new PagePack.Placement[](2);
        placements[0] = accountPlacement(owner, 0);
        placements[1] = approvalPlacement(owner, other, 1);
        spender.pack(placements);

        PagePack.Hint[] memory hints = new PagePack.Hint[](2);
        hints[0] = spender.accountHint(owner);
        hints[1] = spender.approvalHint(owner, other);

        // The account's hint carries its size; the approval's, at the map's own size, doesn't.
        assertEq(hints[0].key, accountKey(owner));
        assertEq(hints[0].hint, (2 << 11) | 1);
        assertEq(hints[1].key, approvalKey(owner, other));
        assertEq(hints[1].hint, 2);

        vm.record();
        vm.prank(other);
        spender.spend(owner, 100, hints);

        // Every slot read is on the packed page: the hints spared both lookups the directory.
        (bytes32[] memory reads,) = vm.accesses(address(spender));
        uint256 page = spender.slotOf(accountKey(owner), 2) >> 7;

        for (uint256 i; i < reads.length; ++i) {
            assertEq(uint256(reads[i]) >> 7, page);
        }

        assertEq(spender.balanceOf(owner), 900);
        assertEq(spender.allowance(owner, other), 200);
    }

    /// Helpers take each kind's size from its struct, including when sending an entry home.
    function test_placementsNameTheirKindsSize() public {
        address owner = makeAddr("owner");

        assertEq(accountPlacement(owner, 3).slots, accountSlots());
        assertEq(approvalPlacement(owner, owner, 4).slots, approvalSlots());

        vm.prank(owner);
        spender.fund(owner, 1_000, 300);

        PagePack.Placement[] memory placements = new PagePack.Placement[](2);
        placements[0] = accountPlacement(owner, 0);
        placements[1] = approvalPlacement(owner, owner, 1);
        spender.pack(placements);

        placements = new PagePack.Placement[](1);
        placements[0] = accountPlacement(owner, PagePack.HOME);
        spender.pack(placements);

        // The account went home whole; the approval stayed packed.
        assertEq(spender.accountHint(owner).hint, 0);
        assertEq(spender.approvalHint(owner, owner).hint, 2);
        assertEq(spender.balanceOf(owner), 1_000);
        assertEq(spender.allowance(owner, owner), 300);
    }

    function _owners(uint256 count) internal returns (address[] memory owners) {
        owners = new address[](count);

        for (uint256 i; i < count; ++i) {
            owners[i] = makeAddr(string.concat("owner", vm.toString(i)));
        }
    }
}
