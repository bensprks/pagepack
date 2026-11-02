// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PagePack} from "pagepack/PagePack.sol";
import {Exchange} from "./Exchange.sol";
import {Account, ExchangeMap, Market, Order, Position, exchangeMap} from "./ExchangeMap.sol";

/// @title PackedExchange
/// @notice Exchange with its records stored by PagePack. The admin applies layouts chosen
///         off-chain, so each active market maker's account, positions and order slots share a
///         page, and every market's record sits on one shared page.
contract PackedExchange is Exchange {
    /// Every record kind shares one typed map, so a layout can mix them on a page. It keeps home
    /// flags for the long-tail takers; the flags cost one slot on the home page of each packed
    /// record, which here means the few hundred records of active accounts.
    ExchangeMap internal immutable RECORDS;

    event Rebalanced(uint256 packedCount);

    /// @param mapName Names the map, which decides where its records are stored and so their
    ///        fingerprints. The benchmarks vary it; any fixed name works.
    constructor(
        IERC20 collateral_,
        address admin_,
        address operator_,
        address feeRecipient_,
        string memory mapName
    ) Exchange(collateral_, admin_, operator_, feeRecipient_) {
        RECORDS = exchangeMap(mapName);
    }

    /// @notice Applies a new layout. Hints issued before this call may go stale; they still
    ///         resolve correctly, just without the saving.
    function rebalance(bytes32[] calldata evictions, PagePack.Placement[] calldata placements)
        external
        onlyAdmin
    {
        RECORDS.map().rebalance(evictions, placements);

        emit Rebalanced(RECORDS.map().packedCount());
    }

    /// @notice The PagePack hint for a record key from ExchangeMap.sol: its packed index plus one,
    ///         or `PagePack.HOME`.
    function hintOf(bytes32 key) external view returns (uint256) {
        return RECORDS.map().hintOf(key);
    }

    function recordsPerPage() external view returns (uint256) {
        return RECORDS.map().recordsPerPage();
    }

    /// PagePack keeps the hints in transient storage, and every lookup picks them up.
    function _useHints(PagePack.Hint[] calldata hints) internal override {
        RECORDS.map().useHints(hints);
    }

    function _account(address trader) internal view override returns (Account storage) {
        return RECORDS.account(trader);
    }

    function _position(address trader, uint8 market)
        internal
        view
        override
        returns (Position storage)
    {
        return RECORDS.position(trader, market);
    }

    function _order(address trader, uint8 index) internal view override returns (Order storage) {
        return RECORDS.order(trader, index);
    }

    function _market(uint8 market) internal view override returns (Market storage) {
        return RECORDS.market(market);
    }
}
