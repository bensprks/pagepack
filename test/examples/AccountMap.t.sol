// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PagePack, PagedMap} from "pagepack/PagePack.sol";
import {
    AccountMap,
    accountKey,
    accountMap,
    accountSlots,
    approvalKey,
    approvalSlots
} from "../../examples/accounts/AccountMap.sol";

/// Loads hints in one call and spends in another, as a contract would within one transaction.
contract Spender {
    AccountMap internal immutable ACCOUNTS = accountMap("test.accounts");

    function spend(address owner, uint128 amount, bytes calldata hints) external {
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

    function hintOf(bytes32 key) external view returns (uint256) {
        return ACCOUNTS.map().hintOf(key);
    }

    function hintsFor(bytes32[] calldata keys) external view returns (bytes memory) {
        return ACCOUNTS.map().packedHintsOf(keys);
    }

    function slotOf(bytes32 key) external view returns (uint256) {
        return ACCOUNTS.map().find(key).slot();
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
        assertEq(m.sizeOf(accountKey(address(1))), 2);
        assertEq(m.sizeOf(approvalKey(address(1), address(2))), 1);
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

            placements[2 * i] = PagePack.Placement(accountKey(owners[i]), 2 * i);
            placements[2 * i + 1] = PagePack.Placement(approvalKey(owners[i], owners[i]), 2 * i + 1);
        }

        spender.pack(placements);

        uint256 page = spender.slotOf(accountKey(owners[0])) >> 7;

        for (uint256 i; i < owners.length; ++i) {
            assertEq(spender.slotOf(accountKey(owners[i])) >> 7, page);
            assertEq(spender.slotOf(approvalKey(owners[i], owners[i])) >> 7, page);
            assertEq(spender.balanceOf(owners[i]), 1_000 + i);
            assertEq(spender.allowance(owners[i], owners[i]), 100 + i);
        }
    }

    /// One run of hints covers both kinds.
    function test_oneHintListServesBothKinds() public {
        address owner = makeAddr("owner");
        address other = makeAddr("other");

        vm.prank(other);
        spender.fund(owner, 1_000, 300);

        PagePack.Placement[] memory placements = new PagePack.Placement[](2);
        placements[0] = PagePack.Placement(accountKey(owner), 0);
        placements[1] = PagePack.Placement(approvalKey(owner, other), 1);
        spender.pack(placements);

        // Both kinds' hints are plain indices, and one call builds the bytes to send.
        bytes32[] memory keys = new bytes32[](2);
        keys[0] = accountKey(owner);
        keys[1] = approvalKey(owner, other);

        assertEq(spender.hintOf(keys[0]), 1);
        assertEq(spender.hintOf(keys[1]), 2);

        bytes memory hints = spender.hintsFor(keys);
        assertEq(hints.length, 10);

        vm.record();
        vm.prank(other);
        spender.spend(owner, 100, hints);

        // Every slot read is on the packed page: the hints spared both lookups the directory.
        (bytes32[] memory reads,) = vm.accesses(address(spender));
        uint256 page = spender.slotOf(accountKey(owner)) >> 7;

        for (uint256 i; i < reads.length; ++i) {
            assertEq(uint256(reads[i]) >> 7, page);
        }

        assertEq(spender.balanceOf(owner), 900);
        assertEq(spender.allowance(owner, other), 200);
    }

    /// A placement names its entry by key alone, including when sending it home.
    function test_placementsNeedNoSize() public {
        address owner = makeAddr("owner");

        vm.prank(owner);
        spender.fund(owner, 1_000, 300);

        PagePack.Placement[] memory placements = new PagePack.Placement[](2);
        placements[0] = PagePack.Placement(accountKey(owner), 0);
        placements[1] = PagePack.Placement(approvalKey(owner, owner), 1);
        spender.pack(placements);

        placements = new PagePack.Placement[](1);
        placements[0] = PagePack.Placement(accountKey(owner), PagePack.HOME);
        spender.pack(placements);

        // The account went home whole; the approval stayed packed.
        assertEq(spender.hintOf(accountKey(owner)), 0);
        assertEq(spender.hintOf(approvalKey(owner, owner)), 2);
        assertEq(spender.balanceOf(owner), 1_000);
        assertEq(spender.allowance(owner, owner), 300);
    }

    /// A key whose top byte names no kind of the map can't be packed.
    function test_unknownKindCannotBePacked() public {
        PagePack.Placement[] memory placements = new PagePack.Placement[](1);
        placements[0] = PagePack.Placement(bytes32(uint256(7) << 248 | 1), 0);

        vm.expectRevert(abi.encodeWithSelector(PagePack.UnknownKind.selector, 7));
        spender.pack(placements);
    }

    function _owners(uint256 count) internal returns (address[] memory owners) {
        owners = new address[](count);

        for (uint256 i; i < count; ++i) {
            owners[i] = makeAddr(string.concat("owner", vm.toString(i)));
        }
    }
}
