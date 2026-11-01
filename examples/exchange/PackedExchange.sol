// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PagePack, Record, Space} from "pagepack/PagePack.sol";
import {Exchange} from "./Exchange.sol";

/// @title PackedExchange
/// @notice Exchange with its records stored by PagePack. The admin applies layouts chosen
///         off-chain, so each active market maker's account, positions and order slots share a
///         page, and every market's record sits on one shared page.
contract PackedExchange is Exchange {
    /// Every record kind shares one space so a layout can mix them on a page.
    Space internal immutable RECORDS = PagePack.space("pagepack.exchange", 1);

    event Rebalanced(uint256 packedCount);

    constructor(IERC20 collateral_, address admin_, address operator_, address feeRecipient_)
        Exchange(collateral_, admin_, operator_, feeRecipient_)
    {}

    /// @notice Applies a new layout. Hints issued before this call may go stale; they still
    ///         resolve correctly, just without the saving.
    function rebalance(bytes32[] calldata evictions, PagePack.Placement[] calldata placements)
        external
        onlyAdmin
    {
        RECORDS.rebalance(evictions, placements);

        emit Rebalanced(RECORDS.packedCount());
    }

    /// @notice The PagePack hint for a record key: its packed index plus one, or `PagePack.HOME`.
    function hintOf(bytes32 key) external view returns (uint256) {
        return RECORDS.hintOf(key);
    }

    function recordsPerPage() external view returns (uint256) {
        return RECORDS.recordsPerPage();
    }

    function _locate(bytes32 key) internal view override returns (Record) {
        return RECORDS.find(key, _hintFor(key));
    }
}
