// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PagePack} from "pagepack/PagePack.sol";
import {TokenLedger} from "../../examples/erc6909/TokenLedger.sol";
import {TokenFacade} from "../../examples/erc6909/TokenFacade.sol";
import {PackedTokenLedger} from "../../examples/erc6909/PackedTokenLedger.sol";
import {MappingTokenLedger} from "../examples/utils/MappingTokenLedger.sol";
import {StandaloneERC20} from "../examples/utils/StandaloneERC20.sol";
import {IERC20, SwapPool} from "../examples/utils/SwapPool.sol";

/// Compares the ERC-6909 example against standalone ERC-20s (what Monad has today) and against
/// the same ledger on plain mappings. Each test is its own transaction, so every page and account
/// starts cold. All balances stay nonzero, so no state-growth charges are included.
///
/// Market: 30 traders hold tokens A and B and have approved a settlement engine as operator. A
/// pool holds both tokens, and trader 0 has approved the pool to pull token A.
///
/// Packed layout, 64 one-word records per page:
///   page 0   the pool's two balances, trader 0's allowance and (empty) operator record for the
///            pool, then traders 0-19: balance A, balance B, operator approval for the settler
///   page 1   traders 20-29, same three records each
contract TokenLedgerGasTest is Test {
    uint256 internal constant TRADERS = 30;
    uint256 internal constant TRADERS_ON_FIRST_PAGE = 20;
    uint256 internal constant FUNDS = 1e24;

    uint256 internal constant A = 0;
    uint256 internal constant B = 1;

    address internal settler = makeAddr("settler");
    address internal admin = makeAddr("admin");
    address[] internal traders;

    StandaloneERC20 internal standaloneA;
    StandaloneERC20 internal standaloneB;
    SwapPool internal standalonePool;

    MappingTokenLedger internal mappingLedger;
    SwapPool internal mappingPool;

    PackedTokenLedger internal packedLedger;
    SwapPool internal packedPool;

    function setUp() public {
        for (uint256 i; i < TRADERS; ++i) {
            traders.push(makeAddr(string.concat("trader", vm.toString(i))));
        }

        _setUpStandalone();

        mappingLedger = new MappingTokenLedger();
        mappingPool = _setUpLedger(mappingLedger);

        packedLedger = new PackedTokenLedger(admin);
        packedPool = _setUpLedger(packedLedger);

        _pack();
    }

    // ------------------------------------------------------------------------------------------
    // Single transfers
    // ------------------------------------------------------------------------------------------

    function test_gas_erc20Transfer_standalone() public {
        vm.prank(traders[0]);
        standaloneA.transfer(traders[1], 1);
        vm.snapshotGasLastCall("erc20-standalone", "ERC-20 transfer");
    }

    function test_gas_erc20Transfer_mapping() public {
        _facadeTransfer(mappingLedger, "ledger-mapping");
    }

    function test_gas_erc20Transfer_packed() public {
        _facadeTransfer(packedLedger, "ledger-pagepack");
    }

    function test_gas_erc6909Transfer_mapping() public {
        _ledgerTransfer(mappingLedger, "ledger-mapping");
    }

    function test_gas_erc6909Transfer_packed() public {
        _ledgerTransfer(packedLedger, "ledger-pagepack");
    }

    // ------------------------------------------------------------------------------------------
    // Swap through a pool, using only the ERC-20 interface
    // ------------------------------------------------------------------------------------------

    function test_gas_swap_standalone() public {
        _swap(standalonePool, "erc20-standalone");
    }

    function test_gas_swap_mapping() public {
        _swap(mappingPool, "ledger-mapping");
    }

    function test_gas_swap_packed() public {
        _swap(packedPool, "ledger-pagepack");
    }

    // ------------------------------------------------------------------------------------------
    // Batch settlement by an operator
    // ------------------------------------------------------------------------------------------

    function test_gas_batch10_mapping() public {
        _settle(mappingLedger, 10, false, "ledger-mapping");
    }

    function test_gas_batch10_packed() public {
        _settle(packedLedger, 10, false, "ledger-pagepack");
    }

    function test_gas_batch10_hinted() public {
        _settle(packedLedger, 10, true, "ledger-pagepack-hinted");
    }

    function test_gas_batch30_mapping() public {
        _settle(mappingLedger, 30, false, "ledger-mapping");
    }

    function test_gas_batch30_packed() public {
        _settle(packedLedger, 30, false, "ledger-pagepack");
    }

    function test_gas_batch30_hinted() public {
        _settle(packedLedger, 30, true, "ledger-pagepack-hinted");
    }

    // ------------------------------------------------------------------------------------------
    // Scenarios
    // ------------------------------------------------------------------------------------------

    function _facadeTransfer(TokenLedger ledger, string memory group) internal {
        TokenFacade tokenA = TokenFacade(ledger.facadeOf(A));

        vm.prank(traders[0]);
        tokenA.transfer(traders[1], 1);
        vm.snapshotGasLastCall(group, "ERC-20 transfer");

        assertEq(ledger.balanceOf(traders[1], A), FUNDS + 1);
    }

    function _ledgerTransfer(TokenLedger ledger, string memory group) internal {
        vm.prank(traders[0]);
        ledger.transfer(traders[1], A, 1);
        vm.snapshotGasLastCall(group, "ERC-6909 transfer");

        assertEq(ledger.balanceOf(traders[1], A), FUNDS + 1);
    }

    function _swap(SwapPool pool, string memory group) internal {
        vm.prank(traders[0]);
        pool.swap(1, 1);
        vm.snapshotGasLastCall(group, "Swap through a pool");
    }

    /// Trader i sends trader i + 1 one unit, alternating between tokens A and B.
    function _settle(TokenLedger ledger, uint256 count, bool hinted, string memory group) internal {
        TokenLedger.Move[] memory moves = new TokenLedger.Move[](count);
        TokenLedger.MoveHints[] memory hints = new TokenLedger.MoveHints[](hinted ? count : 0);

        for (uint256 i; i < count; ++i) {
            address from = traders[i];
            address to = traders[(i + 1) % TRADERS];
            uint256 id = i % 2;

            moves[i] = TokenLedger.Move(from, to, id, 1);

            if (hinted) {
                hints[i] = TokenLedger.MoveHints(
                    packedLedger.hintOf(ledger.balanceKey(from, id)),
                    packedLedger.hintOf(ledger.balanceKey(to, id)),
                    packedLedger.hintOf(ledger.operatorKey(from, settler))
                );
            }
        }

        // Reading hints warmed the ledger's pages. Measure as a fresh transaction.
        if (hinted) vm.cool(address(ledger));

        vm.prank(settler);
        ledger.batchTransferFrom(moves, hints);
        vm.snapshotGasLastCall(
            group, string.concat("Batch settlement, ", vm.toString(count), " moves")
        );

        assertEq(ledger.balanceOf(traders[1], A), FUNDS + 1);
    }

    // ------------------------------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------------------------------

    function _setUpStandalone() internal {
        uint256 supply = FUNDS * (TRADERS + 1);

        standaloneA = new StandaloneERC20(supply, address(this));
        standaloneB = new StandaloneERC20(supply, address(this));
        standalonePool = new SwapPool(IERC20(address(standaloneA)), IERC20(address(standaloneB)));

        standaloneA.transfer(address(standalonePool), FUNDS);
        standaloneB.transfer(address(standalonePool), FUNDS);

        for (uint256 i; i < TRADERS; ++i) {
            standaloneA.transfer(traders[i], FUNDS);
            standaloneB.transfer(traders[i], FUNDS);
        }

        vm.prank(traders[0]);
        standaloneA.approve(address(standalonePool), type(uint256).max);
    }

    function _setUpLedger(TokenLedger ledger) internal returns (SwapPool pool) {
        uint256 supply = FUNDS * (TRADERS + 1);

        (, address tokenA) = ledger.createToken("Token A", "A", 18, supply, address(this));
        (, address tokenB) = ledger.createToken("Token B", "B", 18, supply, address(this));
        pool = new SwapPool(IERC20(tokenA), IERC20(tokenB));

        ledger.transfer(address(pool), A, FUNDS);
        ledger.transfer(address(pool), B, FUNDS);

        for (uint256 i; i < TRADERS; ++i) {
            ledger.transfer(traders[i], A, FUNDS);
            ledger.transfer(traders[i], B, FUNDS);

            vm.prank(traders[i]);
            ledger.setOperator(settler, true);
        }

        vm.prank(traders[0]);
        TokenFacade(tokenA).approve(address(pool), type(uint256).max);
    }

    function _pack() internal {
        PagePack.Placement[] memory placements = new PagePack.Placement[](4 + 3 * TRADERS);
        address pool = address(packedPool);

        // Packing trader 0's empty operator record for the pool makes the operator check that
        // precedes every allowance spend cheap too.
        placements[0] = PagePack.Placement(packedLedger.balanceKey(pool, A), 0);
        placements[1] = PagePack.Placement(packedLedger.balanceKey(pool, B), 1);
        placements[2] = PagePack.Placement(packedLedger.allowanceKey(traders[0], pool, A), 2);
        placements[3] = PagePack.Placement(packedLedger.operatorKey(traders[0], pool), 3);

        for (uint256 i; i < TRADERS; ++i) {
            uint256 base =
                i < TRADERS_ON_FIRST_PAGE ? 4 + 3 * i : 64 + 3 * (i - TRADERS_ON_FIRST_PAGE);
            address trader = traders[i];

            placements[4 + 3 * i] = PagePack.Placement(packedLedger.balanceKey(trader, A), base);
            placements[5 + 3 * i] = PagePack.Placement(packedLedger.balanceKey(trader, B), base + 1);
            placements[6 + 3 * i] =
                PagePack.Placement(packedLedger.operatorKey(trader, settler), base + 2);
        }

        vm.prank(admin);
        packedLedger.rebalance(new bytes32[](0), placements);

        assertEq(packedLedger.recordsPerPage(), 64);
    }
}
