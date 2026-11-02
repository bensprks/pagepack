// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PagePack, PagedMap, Record} from "pagepack/PagePack.sol";

/// Baseline: one Solidity mapping entry per balance.
contract MappingBalances {
    mapping(bytes32 key => uint256) public balanceOf;

    function seed(bytes32[] calldata keys) external {
        for (uint256 i; i < keys.length; ++i) {
            balanceOf[keys[i]] = 1_000;
        }
    }

    function bump(bytes32[] calldata keys) external {
        for (uint256 i; i < keys.length; ++i) {
            balanceOf[keys[i]] += 1;
        }
    }
}

/// The same balances stored as one-slot PagePack records.
contract PackedBalances {
    PagedMap internal immutable BALANCES;

    constructor(bool homeHints) {
        BALANCES = homeHints
            ? PagePack.mapWithHomeHints("bench.balances", 1)
            : PagePack.map("bench.balances", 1);
    }

    function balanceOf(bytes32 key) external view returns (uint256) {
        return BALANCES.find(key).read(0);
    }

    function hintOf(bytes32 key) external view returns (uint256) {
        return BALANCES.hintOf(key);
    }

    function seed(bytes32[] calldata keys) external {
        for (uint256 i; i < keys.length; ++i) {
            BALANCES.find(keys[i]).write(0, 1_000);
        }
    }

    function pack(PagePack.Placement[] calldata placements) external {
        BALANCES.rebalance(new bytes32[](0), placements);
    }

    function bump(bytes32[] calldata keys) external {
        for (uint256 i; i < keys.length; ++i) {
            Record r = BALANCES.find(keys[i]);
            r.write(0, r.read(0) + 1);
        }
    }

    function bump(bytes32[] calldata keys, uint256[] calldata hints) external {
        for (uint256 i; i < keys.length; ++i) {
            Record r = BALANCES.find(keys[i], hints[i]);
            r.write(0, r.read(0) + 1);
        }
    }
}
