// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Record} from "pagepack/PagePack.sol";
import {Exchange} from "../../../examples/exchange/Exchange.sol";

/// Benchmark baseline: the same exchange with every record in an ordinary Solidity mapping, so
/// each account, position, order and market record sits on its own page, as in Perpl today.
contract MappingExchange is Exchange {
    mapping(bytes32 key => uint256) private _records;

    constructor(IERC20 collateral_, address admin_, address operator_, address feeRecipient_)
        Exchange(collateral_, admin_, operator_, feeRecipient_)
    {}

    /// The slot Solidity uses for `_records[key]`. Hints are ignored.
    function _locate(bytes32 key) internal pure override returns (Record r) {
        assembly ("memory-safe") {
            mstore(0x00, key)
            mstore(0x20, _records.slot)
            r := keccak256(0x00, 0x40)
        }
    }
}
