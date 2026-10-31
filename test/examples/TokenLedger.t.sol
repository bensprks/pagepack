// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PagePack} from "pagepack/PagePack.sol";
import {TokenLedger} from "../../examples/erc6909/TokenLedger.sol";
import {TokenFacade} from "../../examples/erc6909/TokenFacade.sol";
import {PackedTokenLedger} from "../../examples/erc6909/PackedTokenLedger.sol";
import {MappingTokenLedger} from "./utils/MappingTokenLedger.sol";

/// ERC-6909 and facade behaviour, run against both storage backends.
abstract contract TokenLedgerTest is Test {
    TokenLedger internal ledger;
    TokenFacade internal facade;
    uint256 internal id;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    event Transfer(
        address caller,
        address indexed sender,
        address indexed receiver,
        uint256 indexed id,
        uint256 amount
    );
    event OperatorSet(address indexed owner, address indexed spender, bool approved);
    event Approval(
        address indexed owner, address indexed spender, uint256 indexed id, uint256 amount
    );

    function _deploy() internal virtual returns (TokenLedger);

    function setUp() public virtual {
        ledger = _deploy();

        address facadeAddress;
        (id, facadeAddress) = ledger.createToken("Test Dollar", "TUSD", 6, 1_000_000, alice);
        facade = TokenFacade(facadeAddress);
    }

    // ------------------------------------------------------------------------------------------
    // Token creation
    // ------------------------------------------------------------------------------------------

    function test_createToken() public view {
        assertEq(id, 0);
        assertEq(ledger.tokenCount(), 1);
        assertEq(ledger.name(id), "Test Dollar");
        assertEq(ledger.symbol(id), "TUSD");
        assertEq(ledger.decimals(id), 6);
        assertEq(ledger.totalSupply(id), 1_000_000);
        assertEq(ledger.balanceOf(alice, id), 1_000_000);
    }

    function test_tokenIdsAreSequential() public {
        (uint256 second,) = ledger.createToken("Second", "TWO", 18, 5, bob);

        assertEq(second, 1);
        assertEq(ledger.balanceOf(bob, second), 5);
        assertEq(ledger.balanceOf(bob, id), 0);
    }

    function test_facadeIsDeployedAtPredictedAddress() public view {
        assertEq(address(facade), ledger.facadeOf(id));
        assertEq(address(facade.ledger()), address(ledger));
        assertEq(facade.id(), id);
    }

    function test_supportsInterface() public view {
        assertTrue(ledger.supportsInterface(0x01ffc9a7));
        assertTrue(ledger.supportsInterface(0x0f632fb3));
        assertFalse(ledger.supportsInterface(0xffffffff));
    }

    // ------------------------------------------------------------------------------------------
    // ERC-6909
    // ------------------------------------------------------------------------------------------

    function test_transfer() public {
        vm.expectEmit(address(ledger));
        emit Transfer(alice, alice, bob, id, 300);

        vm.prank(alice);
        assertTrue(ledger.transfer(bob, id, 300));

        assertEq(ledger.balanceOf(alice, id), 999_700);
        assertEq(ledger.balanceOf(bob, id), 300);
    }

    function test_transferToSelf() public {
        vm.prank(alice);
        ledger.transfer(alice, id, 300);

        assertEq(ledger.balanceOf(alice, id), 1_000_000);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.expectRevert(abi.encodeWithSelector(TokenLedger.InsufficientBalance.selector, bob, id));
        vm.prank(bob);
        ledger.transfer(alice, id, 1);
    }

    function test_approveAndTransferFrom() public {
        vm.expectEmit(address(ledger));
        emit Approval(alice, bob, id, 500);

        vm.prank(alice);
        ledger.approve(bob, id, 500);

        vm.prank(bob);
        ledger.transferFrom(alice, carol, id, 200);

        assertEq(ledger.allowance(alice, bob, id), 300);
        assertEq(ledger.balanceOf(carol, id), 200);
    }

    function test_unlimitedAllowanceIsNotSpent() public {
        vm.prank(alice);
        ledger.approve(bob, id, type(uint256).max);

        vm.prank(bob);
        ledger.transferFrom(alice, carol, id, 200);

        assertEq(ledger.allowance(alice, bob, id), type(uint256).max);
    }

    function test_transferFromRevertsWithoutPermission() public {
        vm.prank(alice);
        ledger.approve(bob, id, 100);

        vm.expectRevert(
            abi.encodeWithSelector(TokenLedger.InsufficientPermission.selector, bob, id)
        );
        vm.prank(bob);
        ledger.transferFrom(alice, carol, id, 101);
    }

    function test_transferFromSelfNeedsNoPermission() public {
        vm.prank(alice);
        ledger.transferFrom(alice, bob, id, 10);

        assertEq(ledger.balanceOf(bob, id), 10);
    }

    function test_operatorSkipsAllowance() public {
        vm.expectEmit(address(ledger));
        emit OperatorSet(alice, bob, true);

        vm.prank(alice);
        ledger.setOperator(bob, true);

        vm.prank(alice);
        ledger.approve(bob, id, 50);

        vm.prank(bob);
        ledger.transferFrom(alice, carol, id, 400);

        assertTrue(ledger.isOperator(alice, bob));
        assertEq(ledger.allowance(alice, bob, id), 50);
        assertEq(ledger.balanceOf(carol, id), 400);
    }

    function test_revokedOperatorFallsBackToAllowance() public {
        vm.startPrank(alice);
        ledger.setOperator(bob, true);
        ledger.setOperator(bob, false);
        vm.stopPrank();

        assertFalse(ledger.isOperator(alice, bob));

        vm.expectRevert(
            abi.encodeWithSelector(TokenLedger.InsufficientPermission.selector, bob, id)
        );
        vm.prank(bob);
        ledger.transferFrom(alice, carol, id, 1);
    }

    // ------------------------------------------------------------------------------------------
    // Batch settlement
    // ------------------------------------------------------------------------------------------

    function test_batchTransferFrom() public {
        vm.prank(alice);
        ledger.transfer(bob, id, 1_000);

        vm.prank(alice);
        ledger.setOperator(carol, true);
        vm.prank(bob);
        ledger.setOperator(carol, true);

        TokenLedger.Move[] memory moves = new TokenLedger.Move[](3);
        moves[0] = TokenLedger.Move(alice, bob, id, 100);
        moves[1] = TokenLedger.Move(bob, carol, id, 50);
        moves[2] = TokenLedger.Move(carol, alice, id, 20);

        vm.prank(carol);
        ledger.batchTransferFrom(moves, new TokenLedger.MoveHints[](0));

        assertEq(ledger.balanceOf(alice, id), 1_000_000 - 1_000 - 100 + 20);
        assertEq(ledger.balanceOf(bob, id), 1_000 + 100 - 50);
        assertEq(ledger.balanceOf(carol, id), 50 - 20);
    }

    function test_batchTransferFromRevertsAtomically() public {
        vm.prank(alice);
        ledger.setOperator(carol, true);

        TokenLedger.Move[] memory moves = new TokenLedger.Move[](2);
        moves[0] = TokenLedger.Move(alice, carol, id, 100);
        moves[1] = TokenLedger.Move(bob, carol, id, 1);

        vm.expectRevert(
            abi.encodeWithSelector(TokenLedger.InsufficientPermission.selector, carol, id)
        );
        vm.prank(carol);
        ledger.batchTransferFrom(moves, new TokenLedger.MoveHints[](0));

        assertEq(ledger.balanceOf(carol, id), 0);
    }

    function test_batchTransferFromRevertsOnHintsLengthMismatch() public {
        vm.expectRevert(TokenLedger.HintsLengthMismatch.selector);
        ledger.batchTransferFrom(new TokenLedger.Move[](2), new TokenLedger.MoveHints[](1));
    }

    // ------------------------------------------------------------------------------------------
    // ERC-20 facade
    // ------------------------------------------------------------------------------------------

    function test_facadeViews() public view {
        assertEq(facade.name(), "Test Dollar");
        assertEq(facade.symbol(), "TUSD");
        assertEq(facade.decimals(), 6);
        assertEq(facade.totalSupply(), 1_000_000);
        assertEq(facade.balanceOf(alice), 1_000_000);
    }

    function test_facadeTransfer() public {
        vm.expectEmit(address(ledger));
        emit Transfer(alice, alice, bob, id, 75);
        vm.expectEmit(address(facade));
        emit TokenFacade.Transfer(alice, bob, 75);

        vm.prank(alice);
        assertTrue(facade.transfer(bob, 75));

        assertEq(facade.balanceOf(bob), 75);
        assertEq(ledger.balanceOf(bob, id), 75);
    }

    function test_facadeApproveAndTransferFrom() public {
        vm.expectEmit(address(facade));
        emit TokenFacade.Approval(alice, bob, 500);

        vm.prank(alice);
        facade.approve(bob, 500);

        assertEq(facade.allowance(alice, bob), 500);
        assertEq(ledger.allowance(alice, bob, id), 500);

        vm.prank(bob);
        facade.transferFrom(alice, carol, 200);

        assertEq(facade.allowance(alice, bob), 300);
        assertEq(facade.balanceOf(carol), 200);
    }

    function test_onlyFacadeCanUseFacadeEntryPoints() public {
        vm.expectRevert(abi.encodeWithSelector(TokenLedger.NotFacade.selector, id));
        vm.prank(bob);
        ledger.facadeTransfer(id, alice, bob, 1);

        // A facade can't act for another token.
        (uint256 other, address otherFacade) = ledger.createToken("Other", "OTH", 18, 1, alice);
        vm.expectRevert(abi.encodeWithSelector(TokenLedger.NotFacade.selector, id));
        vm.prank(otherFacade);
        ledger.facadeApprove(id, alice, bob, 1);

        assertEq(other, 1);
    }
}

contract MappingTokenLedgerTest is TokenLedgerTest {
    function _deploy() internal override returns (TokenLedger) {
        return new MappingTokenLedger();
    }
}

contract PackedTokenLedgerTest is TokenLedgerTest {
    address internal admin = makeAddr("admin");

    function _deploy() internal override returns (TokenLedger) {
        return new PackedTokenLedger(admin);
    }

    function _packed() internal view returns (PackedTokenLedger) {
        return PackedTokenLedger(address(ledger));
    }

    function test_onlyAdminCanRebalance() public {
        vm.expectRevert(PackedTokenLedger.NotAdmin.selector);
        _packed().rebalance(new bytes32[](0), new PagePack.Placement[](0));
    }

    function test_stateSurvivesRebalancing() public {
        vm.startPrank(alice);
        ledger.transfer(bob, id, 1_000);
        ledger.approve(bob, id, 77);
        ledger.setOperator(carol, true);
        vm.stopPrank();

        bytes32[] memory keys = _aliceAndBobKeys();
        PagePack.Placement[] memory placements = new PagePack.Placement[](keys.length);

        for (uint256 i; i < keys.length; ++i) {
            placements[i] = PagePack.Placement(keys[i], i);
        }

        vm.prank(admin);
        _packed().rebalance(new bytes32[](0), placements);

        for (uint256 i; i < keys.length; ++i) {
            assertEq(_packed().hintOf(keys[i]), i + 1);
        }

        _assertAliceAndBob();

        // Evict everything again and check nothing was lost on the way back.
        vm.prank(admin);
        _packed().rebalance(keys, new PagePack.Placement[](0));

        _assertAliceAndBob();
    }

    function test_hintedBatchMatchesUnhintedBatch() public {
        vm.prank(alice);
        ledger.setOperator(carol, true);

        bytes32[] memory keys = new bytes32[](3);
        keys[0] = ledger.balanceKey(alice, id);
        keys[1] = ledger.balanceKey(bob, id);
        keys[2] = ledger.operatorKey(alice, carol);

        PagePack.Placement[] memory placements = new PagePack.Placement[](3);
        for (uint256 i; i < 3; ++i) {
            placements[i] = PagePack.Placement(keys[i], 10 + i);
        }

        vm.prank(admin);
        _packed().rebalance(new bytes32[](0), placements);

        TokenLedger.Move[] memory moves = new TokenLedger.Move[](1);
        moves[0] = TokenLedger.Move(alice, bob, id, 40);

        TokenLedger.MoveHints[] memory hints = new TokenLedger.MoveHints[](1);
        hints[0] = TokenLedger.MoveHints(
            _packed().hintOf(keys[0]), _packed().hintOf(keys[1]), _packed().hintOf(keys[2])
        );

        vm.prank(carol);
        ledger.batchTransferFrom(moves, hints);

        // Stale hints after a move still resolve to the right records.
        vm.prank(admin);
        _packed().rebalance(keys, new PagePack.Placement[](0));

        vm.prank(carol);
        ledger.batchTransferFrom(moves, hints);

        assertEq(ledger.balanceOf(bob, id), 80);
        assertEq(ledger.balanceOf(alice, id), 1_000_000 - 80);
    }

    function _aliceAndBobKeys() internal view returns (bytes32[] memory keys) {
        keys = new bytes32[](4);
        keys[0] = ledger.balanceKey(alice, id);
        keys[1] = ledger.balanceKey(bob, id);
        keys[2] = ledger.allowanceKey(alice, bob, id);
        keys[3] = ledger.operatorKey(alice, carol);
    }

    function _assertAliceAndBob() internal view {
        assertEq(ledger.balanceOf(alice, id), 999_000);
        assertEq(ledger.balanceOf(bob, id), 1_000);
        assertEq(ledger.allowance(alice, bob, id), 77);
        assertTrue(ledger.isOperator(alice, carol));
    }
}
