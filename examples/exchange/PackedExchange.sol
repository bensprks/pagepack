// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PagePack} from "pagepack/PagePack.sol";
import {Exchange} from "./Exchange.sol";
import {Account, ExchangeMap, Market, Order, Position, exchangeMap} from "./ExchangeMap.sol";

/// @title PackedExchange
/// @notice Exchange with its entries stored by PagePack. The admin applies layouts chosen
///         offchain, so each active market maker's account, positions and order slots share a
///         page, and every market's entry sits on one shared page.
contract PackedExchange is Exchange {
    /// Every entry kind shares one typed map, so a layout can mix them on a page. It keeps home
    /// flags for the long-tail takers; the flags cost one slot on the home page of each packed
    /// entry, which here means the few hundred entries of active accounts.
    ExchangeMap internal immutable ENTRIES;

    event Rebalanced(uint256 packedCount);

    /// @param mapName Names the map, which decides where its entries are stored and so their
    ///        fingerprints. The benchmarks vary it; any fixed name works.
    constructor(
        IERC20 collateral_,
        address admin_,
        address operator_,
        address feeRecipient_,
        string memory mapName
    ) Exchange(collateral_, admin_, operator_, feeRecipient_) {
        ENTRIES = exchangeMap(mapName);
    }

    /// @notice Applies a new layout. Hints issued before this call may go stale; they still
    ///         resolve correctly, just without the saving.
    function rebalance(bytes32[] calldata evictions, PagePack.Placement[] calldata placements)
        external
        onlyAdmin
    {
        ENTRIES.map().rebalance(evictions, placements);

        emit Rebalanced(ENTRIES.map().packedCount());
    }

    /// @notice The PagePack hint for an entry key from ExchangeMap.sol: its packed index plus one,
    ///         or `PagePack.HOME`.
    function hintOf(bytes32 key) external view returns (uint256) {
        return ENTRIES.map().hintOf(key);
    }

    function entriesPerPage() external view returns (uint256) {
        return ENTRIES.map().entriesPerPage();
    }

    /// PagePack keeps the hints in transient storage, and every lookup picks them up.
    function _useHints(PagePack.Hint[] calldata hints) internal override {
        ENTRIES.map().useHints(hints);
    }

    function _account(address trader) internal view override returns (Account storage) {
        return ENTRIES.account(trader);
    }

    function _position(address trader, uint8 market)
        internal
        view
        override
        returns (Position storage)
    {
        return ENTRIES.position(trader, market);
    }

    function _order(address trader, uint8 index) internal view override returns (Order storage) {
        return ENTRIES.order(trader, index);
    }

    function _market(uint8 market) internal view override returns (Market storage) {
        return ENTRIES.market(market);
    }
}
