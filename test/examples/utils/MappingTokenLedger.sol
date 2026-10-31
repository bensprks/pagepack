// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Record} from "pagepack/PagePack.sol";
import {TokenLedger} from "../../../examples/erc6909/TokenLedger.sol";

/// Benchmark baseline: the same ledger with every record in an ordinary Solidity mapping.
contract MappingTokenLedger is TokenLedger {
    mapping(bytes32 key => uint256) private _records;

    /// The slot Solidity uses for `_records[key]`. Hints mean nothing here and are ignored.
    function _locate(bytes32 key, uint256) internal pure override returns (Record r) {
        assembly ("memory-safe") {
            mstore(0x00, key)
            mstore(0x20, _records.slot)
            r := keccak256(0x00, 0x40)
        }
    }
}
