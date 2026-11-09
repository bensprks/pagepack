// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PagePack} from "pagepack/PagePack.sol";
import {Exchange} from "../../examples/exchange/Exchange.sol";
import {
    accountKey,
    marketKey,
    orderKey,
    positionKey
} from "../../examples/exchange/ExchangeMap.sol";
import {PackedExchange} from "../../examples/exchange/PackedExchange.sol";
import {MappingExchange} from "./utils/MappingExchange.sol";
import {TestToken} from "./utils/TestToken.sol";

/// Exchange behaviour, run against both storage backends.
abstract contract ExchangeTest is Test {
    uint8 internal constant ETH = 0;
    uint8 internal constant BTC = 1;

    TestToken internal token;
    Exchange internal exchange;

    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal fees = makeAddr("fees");
    address internal maker = makeAddr("maker");
    address internal taker = makeAddr("taker");

    event OrderUpdated(
        address indexed account, uint8 index, uint8 market, bool isAsk, uint64 price, uint64 size
    );
    event Filled(
        uint8 indexed market,
        address indexed maker,
        address indexed taker,
        uint64 size,
        uint64 price
    );

    function _deploy() internal virtual returns (Exchange);

    function setUp() public virtual {
        token = new TestToken();
        exchange = _deploy();

        vm.startPrank(admin);
        exchange.listMarket(ETH, 2_000, 1_000, 10); // 10% margin, 0.1% taker fee
        exchange.listMarket(BTC, 50_000, 500, 10); // 5% margin
        vm.stopPrank();

        _fund(maker, 1_000_000);
        _fund(taker, 1_000_000);
    }

    // ------------------------------------------------------------------------------------------
    // Markets and collateral
    // ------------------------------------------------------------------------------------------

    function test_onlyAdminListsMarkets() public {
        vm.expectRevert(Exchange.NotAdmin.selector);
        exchange.listMarket(2, 1, 1, 1);
    }

    /// Relisting would change the margin rate under resting orders and reset trade stats.
    function test_marketsCannotBeRelisted() public {
        vm.expectRevert(abi.encodeWithSelector(Exchange.MarketExists.selector, ETH));
        vm.prank(admin);
        exchange.listMarket(ETH, 2_000, 2_000, 10);
    }

    function test_markPriceCannotBeZero() public {
        vm.expectRevert(Exchange.InvalidPrice.selector);
        vm.prank(admin);
        exchange.setMarkPrice(ETH, 0);
    }

    function test_depositAndWithdraw() public {
        (uint256 balance,,) = exchange.accountOf(maker);
        assertEq(balance, 1_000_000);

        vm.prank(maker);
        exchange.withdraw(400_000, _noHints());

        (balance,,) = exchange.accountOf(maker);
        assertEq(balance, 600_000);
        assertEq(token.balanceOf(maker), 400_000);
    }

    function test_withdrawRevertsWhenMarginWouldBreak() public {
        _quote(maker, 0, ETH, true, 2_000, 100); // locks 20,000

        vm.expectRevert(abi.encodeWithSelector(Exchange.InsufficientMargin.selector, maker));
        vm.prank(maker);
        exchange.withdraw(990_000, _noHints());
    }

    // ------------------------------------------------------------------------------------------
    // Quoting
    // ------------------------------------------------------------------------------------------

    function test_placingAnOrderLocksMargin() public {
        vm.expectEmit(address(exchange));
        emit OrderUpdated(maker, 3, ETH, true, 2_100, 50);

        _quote(maker, 3, ETH, true, 2_100, 50);

        (uint256 price, uint256 size, uint8 market, bool isAsk) = exchange.orderOf(maker, 3);
        assertEq(price, 2_100);
        assertEq(size, 50);
        assertEq(market, ETH);
        assertTrue(isAsk);

        (, uint256 locked,) = exchange.accountOf(maker);
        assertEq(locked, 50 * 2_100 / 10);
    }

    function test_changingAnOrderMovesLockedMargin() public {
        _quote(maker, 0, ETH, true, 2_100, 50);
        _quote(maker, 0, BTC, false, 49_000, 2);

        (, uint256 locked,) = exchange.accountOf(maker);
        assertEq(locked, 2 * 49_000 * 500 / 10_000);
    }

    function test_cancellingKeepsTheSlotWordForReuse() public {
        _quote(maker, 0, ETH, true, 2_100, 50);
        _quote(maker, 0, ETH, true, 0, 0);

        (uint256 price, uint256 size,,) = exchange.orderOf(maker, 0);
        (, uint256 locked,) = exchange.accountOf(maker);

        assertEq(size, 0);
        assertEq(price, 2_100, "slot word stays nonzero");
        assertEq(locked, 0);
    }

    function test_quoteRevertsWithoutMargin() public {
        vm.expectRevert(abi.encodeWithSelector(Exchange.InsufficientMargin.selector, maker));
        _quote(maker, 0, ETH, true, 2_000, 10_000); // locks 2,000,000
    }

    function test_quoteRevertsForUnknownMarketOrIndex() public {
        vm.expectRevert(abi.encodeWithSelector(Exchange.UnknownMarket.selector, 9));
        _quote(maker, 0, 9, true, 1, 1);

        vm.expectRevert(abi.encodeWithSelector(Exchange.InvalidOrderIndex.selector, 16));
        _quote(maker, 16, ETH, true, 1, 1);
    }

    /// A zero-price bid in market 0 would cancel to an all-zero word, so reusing the slot would
    /// pay the state-growth charge that slot reuse exists to avoid.
    function test_zeroPriceOrdersAreRejected() public {
        vm.expectRevert(Exchange.InvalidPrice.selector);
        _quote(maker, 0, ETH, false, 0, 5);
    }

    // ------------------------------------------------------------------------------------------
    // Settlement
    // ------------------------------------------------------------------------------------------

    function test_settleMovesPositionsMarginAndFees() public {
        _quote(maker, 0, ETH, true, 2_000, 50);

        vm.expectEmit(address(exchange));
        emit Filled(ETH, maker, taker, 20, 2_000);

        _settle(taker, _fill(maker, 0, 20));

        (int256 makerSize, int256 makerCost) = exchange.positionOf(maker, ETH);
        (int256 takerSize, int256 takerCost) = exchange.positionOf(taker, ETH);
        assertEq(makerSize, -20);
        assertEq(makerCost, -40_000);
        assertEq(takerSize, 20);
        assertEq(takerCost, 40_000);

        (, uint256 makerLocked, uint256 makerMarkets) = exchange.accountOf(maker);
        assertEq(makerLocked, 30 * 2_000 / 10);
        assertEq(makerMarkets, 1 << ETH);

        (uint256 takerBalance,,) = exchange.accountOf(taker);
        (uint256 feeBalance,,) = exchange.accountOf(fees);
        assertEq(takerBalance, 1_000_000 - 40);
        assertEq(feeBalance, 40);

        (,,, uint256 last, uint256 volume) = exchange.marketOf(ETH);
        assertEq(last, 2_000);
        assertEq(volume, 20);

        (, uint256 remaining,,) = exchange.orderOf(maker, 0);
        assertEq(remaining, 30);
    }

    /// 10 lots at 2,001 with 10% margin lock 2,001. Releasing each one-lot fill's own rounded
    /// share would free only 200 × 10 and strand 1 forever.
    function test_partialFillsReleaseTheWholeReservation() public {
        _quote(maker, 0, ETH, true, 2_001, 10);

        (, uint256 locked,) = exchange.accountOf(maker);
        assertEq(locked, 2_001);

        for (uint256 i; i < 10; ++i) {
            _settle(taker, _fill(maker, 0, 1));
        }

        (, uint256 remaining,,) = exchange.orderOf(maker, 0);
        (, locked,) = exchange.accountOf(maker);

        assertEq(remaining, 0);
        assertEq(locked, 0);
    }

    function test_closingAPositionRealizesProfit() public {
        address other = makeAddr("other");
        _fund(other, 1_000_000);

        _quote(maker, 0, ETH, true, 2_000, 10);
        _settle(taker, _fill(maker, 0, 10)); // taker buys 10 at 2,000

        _quote(other, 0, ETH, false, 2_100, 10);
        _settle(taker, _fill(other, 0, 10)); // taker sells 10 at 2,100

        (int256 size, int256 cost) = exchange.positionOf(taker, ETH);
        (uint256 balance,, uint256 markets) = exchange.accountOf(taker);

        assertEq(size, 0);
        assertEq(cost, 0);
        assertEq(markets, 0);
        assertEq(balance, 1_000_000 + 1_000 - 20 - 21);
    }

    function test_settleAgainstSeveralMakers() public {
        address second = makeAddr("second");
        _fund(second, 1_000_000);

        _quote(maker, 0, ETH, true, 2_000, 5);
        _quote(second, 4, BTC, true, 50_000, 1);

        Exchange.Fill[] memory fills = new Exchange.Fill[](2);
        fills[0] = Exchange.Fill(maker, 0, 5);
        fills[1] = Exchange.Fill(second, 4, 1);
        _settle(taker, fills);

        (,, uint256 markets) = exchange.accountOf(taker);
        assertEq(markets, (1 << ETH) | (1 << BTC));
    }

    function test_settleChecksTakerMargin() public {
        address poor = makeAddr("poor");
        _fund(poor, 1_000);
        _quote(maker, 0, ETH, true, 2_000, 50);

        vm.expectRevert(abi.encodeWithSelector(Exchange.InsufficientMargin.selector, poor));
        _settle(poor, _fill(maker, 0, 50));
    }

    function test_settleRejectsBadFills() public {
        _quote(maker, 0, ETH, true, 2_000, 5);

        vm.expectRevert(Exchange.InvalidFill.selector);
        _settle(taker, _fill(maker, 0, 6));

        vm.expectRevert(Exchange.InvalidFill.selector);
        _settle(maker, _fill(maker, 0, 1));
    }

    function test_onlyOperatorSettles() public {
        vm.expectRevert(Exchange.NotOperator.selector);
        exchange.settle(taker, _fill(maker, 0, 1), _noHints());
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    function _fund(address account, uint256 amount) internal {
        token.mint(account, amount);

        vm.startPrank(account);
        token.approve(address(exchange), amount);
        exchange.deposit(amount);
        vm.stopPrank();
    }

    function _quote(
        address account,
        uint8 index,
        uint8 market,
        bool isAsk,
        uint64 price,
        uint64 size
    ) internal {
        Exchange.QuoteUpdate[] memory updates = new Exchange.QuoteUpdate[](1);
        updates[0] = Exchange.QuoteUpdate(index, market, isAsk, price, size);

        vm.prank(account);
        exchange.requote(updates, _noHints());
    }

    function _settle(address account, Exchange.Fill[] memory fills) internal {
        vm.prank(operator);
        exchange.settle(account, fills, _noHints());
    }

    function _fill(address account, uint8 index, uint64 size)
        internal
        pure
        returns (Exchange.Fill[] memory fills)
    {
        fills = new Exchange.Fill[](1);
        fills[0] = Exchange.Fill(account, index, size);
    }

    function _noHints() internal pure returns (PagePack.Hint[] memory) {}
}

contract MappingExchangeTest is ExchangeTest {
    function _deploy() internal override returns (Exchange) {
        return new MappingExchange(IERC20(address(token)), admin, operator, fees);
    }
}

contract PackedExchangeTest is ExchangeTest {
    function _deploy() internal override returns (Exchange) {
        return
            new PackedExchange(IERC20(address(token)), admin, operator, fees, "pagepack.exchange");
    }

    function _packed() internal view returns (PackedExchange) {
        return PackedExchange(address(exchange));
    }

    function test_onlyAdminCanRebalance() public {
        vm.expectRevert(Exchange.NotAdmin.selector);
        _packed().rebalance(new PagePack.Placement[](0));
    }

    function test_stateSurvivesRebalancing() public {
        _quote(maker, 0, ETH, true, 2_000, 50);
        _settle(taker, _fill(maker, 0, 20));

        bytes32[] memory keys = _makerKeys();
        _pack(keys);

        for (uint256 i; i < keys.length; ++i) {
            assertEq(_packed().hintOf(keys[i]), i + 1);
        }

        _assertMakerState();

        vm.prank(admin);
        _packed().rebalance(_evictions(keys));

        _assertMakerState();
    }

    function test_hintsAndStaleHintsGiveTheSameResult() public {
        _quote(maker, 0, ETH, true, 2_000, 50);

        bytes32[] memory keys = _makerKeys();
        _pack(keys);

        PagePack.Hint[] memory hints = new PagePack.Hint[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            hints[i] = PagePack.Hint(keys[i], _packed().hintOf(keys[i]));
        }

        vm.prank(operator);
        exchange.settle(taker, _fill(maker, 0, 10), hints);

        // Evict everything: every hint is now stale but must still resolve correctly.
        vm.prank(admin);
        _packed().rebalance(_evictions(keys));

        vm.prank(operator);
        exchange.settle(taker, _fill(maker, 0, 10), hints);

        (int256 size,) = exchange.positionOf(maker, ETH);
        assertEq(size, -20);
    }

    function _makerKeys() internal view returns (bytes32[] memory keys) {
        keys = new bytes32[](5);
        keys[0] = accountKey(maker);
        keys[1] = orderKey(maker, 0);
        keys[2] = positionKey(maker, ETH);
        keys[3] = marketKey(ETH);
        keys[4] = accountKey(fees);
    }

    function _pack(bytes32[] memory keys) internal {
        PagePack.Placement[] memory placements = new PagePack.Placement[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            placements[i] = PagePack.Placement(keys[i], 0, i);
        }

        vm.prank(admin);
        _packed().rebalance(placements);
    }

    function _evictions(bytes32[] memory keys)
        internal
        pure
        returns (PagePack.Placement[] memory placements)
    {
        placements = new PagePack.Placement[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            placements[i] = PagePack.Placement(keys[i], 0, PagePack.HOME);
        }
    }

    function _assertMakerState() internal view {
        (int256 size,) = exchange.positionOf(maker, ETH);
        (, uint256 remaining,,) = exchange.orderOf(maker, 0);
        (uint256 markPrice,,,, uint256 volume) = exchange.marketOf(ETH);
        (, uint256 locked,) = exchange.accountOf(maker);

        assertEq(size, -20);
        assertEq(remaining, 30);
        assertEq(markPrice, 2_000);
        assertEq(volume, 20);
        assertEq(locked, 30 * 2_000 / 10);
    }
}
