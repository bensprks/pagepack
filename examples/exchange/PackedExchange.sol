// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PagePack, PagedMap, Record} from "pagepack/PagePack.sol";
import {Exchange} from "./Exchange.sol";

/// @title PackedExchange
/// @notice Exchange with its records stored by PagePack. The admin applies layouts chosen
///         off-chain, so each active market maker's account, positions and order slots share a
///         page, and every market's record sits on one shared page.
contract PackedExchange is Exchange {
    /// Every record kind shares one map so a layout can mix them on a page. It keeps home flags:
    /// takers are long-tail accounts that are never packed, and with a HOME hint for the taker a
    /// fully hinted settlement never loads the directory. The flags cost one slot on the home page
    /// of each packed record, which here means the few hundred records of active accounts.
    PagedMap internal immutable RECORDS;

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
        RECORDS = PagePack.mapWithHomeHints(mapName, 1);
    }

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

    /// PagePack keeps the hints in transient storage, and {_locate} picks them up.
    function _useHints(PagePack.Hint[] calldata hints) internal override {
        RECORDS.useHints(hints);
    }

    function _locate(bytes32 key) internal view override returns (Record) {
        return RECORDS.find(key);
    }
}
