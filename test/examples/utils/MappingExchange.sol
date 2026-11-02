// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PagePack} from "pagepack/PagePack.sol";
import {Exchange} from "../../../examples/exchange/Exchange.sol";
import {
    Account,
    Market,
    Order,
    Position,
    orderKey,
    positionKey
} from "../../../examples/exchange/ExchangeMap.sol";

/// Benchmark baseline: the same exchange with every record in an ordinary Solidity mapping, so
/// each account, position, order and market record sits on its own page, as in Perpl today.
/// Positions and orders are keyed like the packed exchange's, so every lookup hashes once in
/// both versions.
contract MappingExchange is Exchange {
    mapping(address trader => Account) private _accounts;
    mapping(bytes32 key => Position) private _positions;
    mapping(bytes32 key => Order) private _orders;
    mapping(uint8 market => Market) private _markets;

    constructor(IERC20 collateral_, address admin_, address operator_, address feeRecipient_)
        Exchange(collateral_, admin_, operator_, feeRecipient_)
    {}

    /// Mappings have nothing to hint.
    function _useHints(PagePack.Hint[] calldata) internal pure override {}

    function _account(address trader) internal view override returns (Account storage) {
        return _accounts[trader];
    }

    function _position(address trader, uint8 market)
        internal
        view
        override
        returns (Position storage)
    {
        return _positions[positionKey(trader, market)];
    }

    function _order(address trader, uint8 index) internal view override returns (Order storage) {
        return _orders[orderKey(trader, index)];
    }

    function _market(uint8 market) internal view override returns (Market storage) {
        return _markets[market];
    }
}
