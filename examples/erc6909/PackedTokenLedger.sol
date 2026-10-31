// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PagePack, Record, Space} from "pagepack/PagePack.sol";
import {TokenLedger} from "./TokenLedger.sol";

/// @title PackedTokenLedger
/// @notice TokenLedger with its records stored by PagePack. A trusted admin applies layouts
///         chosen off-chain, so accounts that trade together end up sharing pages.
contract PackedTokenLedger is TokenLedger {
    /// Balances, allowances and operator approvals share one space, so a layout can put an
    /// account's balances next to its approval for the router or settlement engine it uses.
    Space internal immutable RECORDS = PagePack.space("pagepack.erc6909", 1);

    address public immutable admin;

    event Rebalanced(uint256 packedCount);

    error NotAdmin();

    constructor(address admin_) {
        admin = admin_;
    }

    /// @notice Applies a new layout. Hints issued before this call may go stale; they still
    ///         resolve correctly, just without the gas saving.
    function rebalance(bytes32[] calldata evictions, PagePack.Placement[] calldata placements)
        external
    {
        if (msg.sender != admin) revert NotAdmin();

        RECORDS.rebalance(evictions, placements);

        emit Rebalanced(RECORDS.packedCount());
    }

    /// @notice The PagePack hint for a record key, or 0 if it is not packed.
    function hintOf(bytes32 key) external view returns (uint256) {
        return RECORDS.hintOf(key);
    }

    function recordsPerPage() external view returns (uint256) {
        return RECORDS.recordsPerPage();
    }

    function _locate(bytes32 key, uint256 hint) internal view override returns (Record) {
        return RECORDS.find(key, hint);
    }
}
