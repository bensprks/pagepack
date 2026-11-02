// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PagePack} from "pagepack/PagePack.sol";
import {Exchange} from "../../examples/exchange/Exchange.sol";
import {PackedExchange} from "../../examples/exchange/PackedExchange.sol";
import {MappingExchange} from "../examples/utils/MappingExchange.sol";
import {TestToken} from "../examples/utils/TestToken.sol";

/// Benchmarks the exchange example on the transaction shapes that dominate Perpl and Tiny on
/// Monad mainnet. Each test is its own transaction, so every page starts cold.
///
/// Market: 8 markets and 16 makers. Maker 0 trades like Perpl's busiest account: positions in 6
/// markets and 8 resting orders across them. Makers 1-15 each hold a position and 4 asks in
/// market 1. The taker is a long-tail account and is never packed.
///
/// Packed layout, 64 one-slot records per page:
///   page 0   all 8 market records, the fee account, maker 0 (account, 8 order slots, 6
///            positions) and makers 1-6 (account, 4 order slots, 1 position each)
///   page 1   makers 7-15
///
/// Each maker's records sit on one page; _pack asserts it.
contract ExchangeGasTest is Test {
    uint8 internal constant MARKETS = 8;
    uint8 internal constant BOOK = 1;
    uint256 internal constant MAKERS = 16;
    uint256 internal constant RECORDS_PER_PAGE = 64;
    string internal constant MAP_NAME = "pagepack.exchange";

    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal fees = makeAddr("fees");
    address internal taker = makeAddr("taker");
    address internal seeder = makeAddr("seeder");
    address[] internal makers;

    TestToken internal token;
    MappingExchange internal mappingExchange;
    PackedExchange internal packedExchange;

    function setUp() public {
        token = new TestToken();

        for (uint256 i; i < MAKERS; ++i) {
            makers.push(makeAddr(string.concat("maker", vm.toString(i))));
        }

        mappingExchange = new MappingExchange(IERC20(address(token)), admin, operator, fees);
        packedExchange = _deployPacked(MAP_NAME);

        _setUpMarket(mappingExchange);
        _setUpMarket(packedExchange);
        _pack(packedExchange);
    }

    // ------------------------------------------------------------------------------------------
    // Quote management
    // ------------------------------------------------------------------------------------------

    function test_gas_requoteMultiMarket_mapping() public {
        _requoteOne(mappingExchange, false, "exchange-mapping");
    }

    function test_gas_requoteMultiMarket_packed() public {
        _requoteOne(packedExchange, false, "exchange-pagepack");
    }

    function test_gas_requoteMultiMarket_hinted() public {
        _requoteOne(packedExchange, true, "exchange-pagepack-hinted");
    }

    function test_gas_requoteThree_mapping() public {
        _requoteThree(mappingExchange, false, "exchange-mapping");
    }

    function test_gas_requoteThree_packed() public {
        _requoteThree(packedExchange, false, "exchange-pagepack");
    }

    function test_gas_requoteThree_hinted() public {
        _requoteThree(packedExchange, true, "exchange-pagepack-hinted");
    }

    // ------------------------------------------------------------------------------------------
    // Settlement
    // ------------------------------------------------------------------------------------------

    function test_gas_settle3_mapping() public {
        _settle(mappingExchange, 3, false, "exchange-mapping");
    }

    function test_gas_settle3_packed() public {
        _settle(packedExchange, 3, false, "exchange-pagepack");
    }

    function test_gas_settle3_hinted() public {
        _settle(packedExchange, 3, true, "exchange-pagepack-hinted");
    }

    function test_gas_settle14_mapping() public {
        _settle(mappingExchange, 14, false, "exchange-mapping");
    }

    function test_gas_settle14_packed() public {
        _settle(packedExchange, 14, false, "exchange-pagepack");
    }

    function test_gas_settle14_hinted() public {
        _settle(packedExchange, 14, true, "exchange-pagepack-hinted");
    }

    // ------------------------------------------------------------------------------------------
    // Map names
    // ------------------------------------------------------------------------------------------

    /// A map's name decides every record's fingerprint, and with it how many probes each
    /// directory search takes. Settles 14 makers without hints in exchanges that differ only in
    /// their map's name.
    function test_gas_settle14_byMapName() public {
        for (uint256 i; i < 6; ++i) {
            string memory name = i == 0 ? MAP_NAME : string.concat(MAP_NAME, ".", vm.toString(i));

            PackedExchange exchange = _deployPacked(name);
            _setUpMarket(exchange);
            _pack(exchange);

            // Setting up warmed the exchange's pages; measure as a fresh transaction.
            vm.cool(address(exchange));
            _settle(exchange, 14, false, "exchange-map-names", name);
        }
    }

    // ------------------------------------------------------------------------------------------
    // Order slot reuse
    // ------------------------------------------------------------------------------------------

    // Both on the mapping exchange, where each slot has its own page either way, so the only
    // difference is whether the slot's word was ever nonzero.

    function test_gas_freshSlot() public {
        _placeInSlot(9, "New order in a never-used slot");
    }

    function test_gas_reusedSlot() public {
        _placeInSlot(3, "New order in a reused slot");
    }

    function _placeInSlot(uint8 index, string memory scenario) internal {
        Exchange.QuoteUpdate[] memory updates = new Exchange.QuoteUpdate[](1);
        updates[0] = Exchange.QuoteUpdate(index, BOOK, true, 2_010, 4);

        vm.prank(makers[2]);
        mappingExchange.requote(updates, _none());
        vm.snapshotGasLastCall("exchange-slots", scenario);
    }

    // ------------------------------------------------------------------------------------------
    // Scenarios
    // ------------------------------------------------------------------------------------------

    /// Maker 0 moves one quote; the margin check reads all 6 of its positions and markets.
    function _requoteOne(Exchange exchange, bool hinted, string memory group) internal {
        Exchange.QuoteUpdate[] memory updates = new Exchange.QuoteUpdate[](1);
        updates[0] = Exchange.QuoteUpdate(0, 0, true, 2_010, 5);

        PagePack.Hint[] memory hints = hinted ? _hints(_makerKeys(makers[0], 8, 6)) : _none();
        _coolIfHinted(exchange, hinted);

        vm.prank(makers[0]);
        exchange.requote(updates, hints);
        vm.snapshotGasLastCall(group, "Re-quote 1 order, maker in 6 markets");
    }

    function _requoteThree(Exchange exchange, bool hinted, string memory group) internal {
        Exchange.QuoteUpdate[] memory updates = new Exchange.QuoteUpdate[](3);
        for (uint8 i; i < 3; ++i) {
            updates[i] = Exchange.QuoteUpdate(i, BOOK, true, 2_005 + i, 4);
        }

        PagePack.Hint[] memory hints = hinted ? _hints(_makerKeys(makers[1], 4, 1)) : _none();
        _coolIfHinted(exchange, hinted);

        vm.prank(makers[1]);
        exchange.requote(updates, hints);
        vm.snapshotGasLastCall(group, "Re-quote 3 orders, one market");
    }

    /// The taker buys one lot from each of the first `count` of makers 1-15.
    function _settle(Exchange exchange, uint256 count, bool hinted, string memory group) internal {
        string memory scenario = string.concat("Taker vs ", vm.toString(count), " makers");
        _settle(exchange, count, hinted, group, scenario);
    }

    function _settle(
        Exchange exchange,
        uint256 count,
        bool hinted,
        string memory group,
        string memory scenario
    ) internal {
        Exchange.Fill[] memory fills = new Exchange.Fill[](count);
        bytes32[] memory keys = new bytes32[](count * 3 + 4);

        for (uint256 i; i < count; ++i) {
            address maker = makers[1 + i];
            fills[i] = Exchange.Fill(maker, 0, 1);

            keys[3 * i] = exchange.accountKey(maker);
            keys[3 * i + 1] = exchange.orderKey(maker, 0);
            keys[3 * i + 2] = exchange.positionKey(maker, BOOK);
        }
        keys[count * 3] = exchange.marketKey(BOOK);
        keys[count * 3 + 1] = exchange.accountKey(fees);

        // The operator knows the taker too, though its records aren't packed.
        keys[count * 3 + 2] = exchange.accountKey(taker);
        keys[count * 3 + 3] = exchange.positionKey(taker, BOOK);

        PagePack.Hint[] memory hints = hinted ? _hints(keys) : _none();
        _coolIfHinted(exchange, hinted);

        vm.prank(operator);
        exchange.settle(taker, fills, hints);
        vm.snapshotGasLastCall(group, scenario);
    }

    // ------------------------------------------------------------------------------------------
    // Hints
    // ------------------------------------------------------------------------------------------

    /// Hints for `keys`, as an off-chain caller would build them. Records that aren't packed get
    /// PagePack.HOME.
    function _hints(bytes32[] memory keys) internal view returns (PagePack.Hint[] memory hints) {
        hints = new PagePack.Hint[](keys.length);

        for (uint256 i; i < keys.length; ++i) {
            hints[i] = PagePack.Hint(keys[i], packedExchange.hintOf(keys[i]));
        }
    }

    /// Reading hints warmed the exchange's pages; measure as a fresh transaction.
    function _coolIfHinted(Exchange exchange, bool hinted) internal {
        if (hinted) vm.cool(address(exchange));
    }

    function _makerKeys(address maker, uint8 orders, uint8 positions)
        internal
        view
        returns (bytes32[] memory keys)
    {
        keys = new bytes32[](1 + orders + 2 * positions);
        keys[0] = packedExchange.accountKey(maker);

        for (uint8 i; i < orders; ++i) {
            keys[1 + i] = packedExchange.orderKey(maker, i);
        }

        // A single-market maker trades in the book market; maker 0 holds markets 0-5.
        for (uint8 i; i < positions; ++i) {
            uint8 market = positions == 1 ? BOOK : i;
            keys[1 + orders + 2 * i] = packedExchange.positionKey(maker, market);
            keys[2 + orders + 2 * i] = packedExchange.marketKey(market);
        }
    }

    function _none() internal pure returns (PagePack.Hint[] memory) {}

    // ------------------------------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------------------------------

    function _setUpMarket(Exchange exchange) internal {
        vm.startPrank(admin);
        for (uint8 m; m < MARKETS; ++m) {
            exchange.listMarket(m, 2_000, 1_000, 10);
        }
        vm.stopPrank();

        _fund(exchange, seeder);
        _fund(exchange, taker);

        // Maker 0: a position in each of markets 0-5, then 8 resting asks across them.
        _fund(exchange, makers[0]);
        for (uint8 m; m < 6; ++m) {
            _quoteAndHit(exchange, makers[0], m, 0);
        }
        Exchange.QuoteUpdate[] memory quotes = new Exchange.QuoteUpdate[](8);
        for (uint8 i; i < 8; ++i) {
            quotes[i] = Exchange.QuoteUpdate(i, i % 6, true, 2_020, 5);
        }
        vm.prank(makers[0]);
        exchange.requote(quotes, _none());

        // Makers 1-15: a position in the book market, then 4 resting asks there.
        for (uint256 i = 1; i < MAKERS; ++i) {
            _fund(exchange, makers[i]);
            _quoteAndHit(exchange, makers[i], BOOK, 0);

            quotes = new Exchange.QuoteUpdate[](4);
            for (uint8 s; s < 4; ++s) {
                quotes[s] = Exchange.QuoteUpdate(s, BOOK, true, 2_001 + s, 5);
            }
            vm.prank(makers[i]);
            exchange.requote(quotes, _none());
        }

        // The taker already holds a position, as an active trader would.
        _quoteAndHit(exchange, seeder, BOOK, 15);

        // Maker 2 cancels its slot 3 order, leaving a reusable slot.
        quotes = new Exchange.QuoteUpdate[](1);
        quotes[0] = Exchange.QuoteUpdate(3, BOOK, true, 0, 0);
        vm.prank(makers[2]);
        exchange.requote(quotes, _none());
    }

    /// Opens a position for `maker` by resting an ask at order `index` that the seeder (or the taker,
    /// for the seeder's own ask) takes in full.
    function _quoteAndHit(Exchange exchange, address maker, uint8 market, uint8 index) internal {
        Exchange.QuoteUpdate[] memory quote = new Exchange.QuoteUpdate[](1);
        quote[0] = Exchange.QuoteUpdate(index, market, true, 2_000, 2);
        vm.prank(maker);
        exchange.requote(quote, _none());

        Exchange.Fill[] memory fills = new Exchange.Fill[](1);
        fills[0] = Exchange.Fill(maker, index, 2);
        vm.prank(operator);
        exchange.settle(maker == seeder ? taker : seeder, fills, _none());
    }

    function _deployPacked(string memory name) internal returns (PackedExchange) {
        return new PackedExchange(IERC20(address(token)), admin, operator, fees, name);
    }

    function _fund(Exchange exchange, address account) internal {
        token.mint(account, 1e12);

        vm.startPrank(account);
        token.approve(address(exchange), 1e12);
        exchange.deposit(1e12);
        vm.stopPrank();
    }

    function _pack(PackedExchange exchange) internal {
        PagePack.Placement[] memory placements = new PagePack.Placement[](RECORDS_PER_PAGE * 2);
        uint256 count;
        uint256 next;

        bytes32[] memory shared = new bytes32[](MARKETS + 1);
        for (uint8 m; m < MARKETS; ++m) {
            shared[m] = exchange.marketKey(m);
        }
        shared[MARKETS] = exchange.accountKey(fees);

        (count, next) = _placeGroup(placements, count, next, shared);

        for (uint256 i; i < MAKERS; ++i) {
            (count, next) = _placeGroup(placements, count, next, _ownKeys(i));
        }

        assembly ("memory-safe") {
            mstore(placements, count)
        }

        vm.prank(admin);
        exchange.rebalance(new bytes32[](0), placements);

        assertEq(exchange.recordsPerPage(), RECORDS_PER_PAGE);

        // Fixture invariant: each maker's records share one page.
        for (uint256 i; i < MAKERS; ++i) {
            bytes32[] memory keys = _ownKeys(i);
            uint256 page = (exchange.hintOf(keys[0]) - 1) / RECORDS_PER_PAGE;

            for (uint256 k = 1; k < keys.length; ++k) {
                assertEq((exchange.hintOf(keys[k]) - 1) / RECORDS_PER_PAGE, page, "split maker");
            }
        }
    }

    /// A maker's own records: its account, order slots and positions.
    function _ownKeys(uint256 index) internal view returns (bytes32[] memory keys) {
        address maker = makers[index];
        uint8 orders = index == 0 ? 8 : 4;
        uint8 positions = index == 0 ? 6 : 1;

        keys = new bytes32[](1 + orders + positions);
        keys[0] = packedExchange.accountKey(maker);

        for (uint8 s; s < orders; ++s) {
            keys[1 + s] = packedExchange.orderKey(maker, s);
        }

        for (uint8 p; p < positions; ++p) {
            keys[1 + orders + p] = packedExchange.positionKey(maker, index == 0 ? p : BOOK);
        }
    }

    /// Places `keys` at consecutive indices from `next`, first moving to the next page if they
    /// would not fit on the current one.
    function _placeGroup(
        PagePack.Placement[] memory placements,
        uint256 count,
        uint256 next,
        bytes32[] memory keys
    ) internal pure returns (uint256, uint256) {
        uint256 offset = next % RECORDS_PER_PAGE;
        if (offset + keys.length > RECORDS_PER_PAGE) next += RECORDS_PER_PAGE - offset;

        for (uint256 i; i < keys.length; ++i) {
            placements[count++] = PagePack.Placement(keys[i], next++);
        }

        return (count, next);
    }
}
