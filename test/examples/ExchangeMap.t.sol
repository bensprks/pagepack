// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {
    ExchangeMap,
    accountKey,
    exchangeMap,
    marketKey,
    orderKey,
    positionKey
} from "../../examples/exchange/ExchangeMap.sol";

/// The exchange's typed map: four kinds of one-slot entry in one map.
contract ExchangeMapTest is Test {
    ExchangeMap internal immutable ENTRIES = exchangeMap("test.exchange");

    address internal trader = makeAddr("trader");

    function test_mapIsOneSlotWideWithHomeHints() public view {
        assertEq(ENTRIES.map().width(), 1);
        assertTrue(ENTRIES.map().homeHints());
    }

    /// Keys decide where entries live, so their layout is fixed once entries are written.
    function test_keysPackTheirKindAndNaturalKey() public view {
        uint256 bits = uint160(trader);

        assertEq(accountKey(trader), bytes32((1 << 248) | bits));
        assertEq(positionKey(trader, 5), bytes32((2 << 248) | (5 << 160) | bits));
        assertEq(orderKey(trader, 3), bytes32((3 << 248) | (3 << 160) | bits));
        assertEq(marketKey(7), bytes32(uint256((4 << 248) | 7)));
    }

    function test_eachGetterUsesItsKindsKey() public {
        ENTRIES.account(trader).balance = 1;
        ENTRIES.position(trader, 2).size = 2;
        ENTRIES.order(trader, 2).price = 3;
        ENTRIES.market(2).markPrice = 4;

        assertEq(ENTRIES.map().find(accountKey(trader)).read(0), 1);
        assertEq(ENTRIES.map().find(positionKey(trader, 2)).read(0), 2);
        assertEq(ENTRIES.map().find(orderKey(trader, 2)).read(0), 3);
        assertEq(ENTRIES.map().find(marketKey(2)).read(0), 4);
    }
}
