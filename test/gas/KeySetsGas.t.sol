// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PagePack} from "pagepack/PagePack.sol";
import {PackedBalances} from "../utils/Balances.sol";

/// Measures updating packed one-slot balances, as PagePackGas does, over 16 key sets, and records
/// the mean, lowest and highest. A lookup without a hint searches the directory, and how many
/// words the search reads depends on the packed entries' fingerprints, so one key set can be
/// several percent off the mean. Hinted lookups, each passed a 2-byte hint as in PagePackGas,
/// skip the search and barely vary.
///
/// Each set packs 494 entries, as PagePackGas does: the measured ones fill page 0, and the rest
/// give the directory the same depth.
contract KeySetsGasTest is Test {
    uint256 internal constant SETS = 16;
    uint256 internal constant PACKED = 494;
    uint256 internal constant FILLER_START = 448;

    PackedBalances[SETS] internal stores;
    uint256[SETS] internal salts;

    function setUp() public {
        uint256 salt;

        for (uint256 s; s < SETS; ++s) {
            PackedBalances store;

            // A set whose fingerprints clash can't all be packed; take the next.
            while (address(store) == address(0)) {
                store = this.build(salt++);
            }

            stores[s] = store;
            salts[s] = salt - 1;
        }
    }

    /// Builds one set in its own call, so its arrays don't pile up in this contract's memory.
    function build(uint256 salt) external returns (PackedBalances store) {
        store = new PackedBalances(false);
        store.seed(_keys(salt, 64));

        PagePack.Placement[] memory placements = new PagePack.Placement[](PACKED);
        for (uint256 i; i < PACKED; ++i) {
            uint256 index = i < 64 ? i : FILLER_START + i - 64;
            placements[i] = PagePack.Placement(_key(salt, i), index);
        }

        try store.pack(placements) {}
        catch {
            store = PackedBalances(address(0));
        }
    }

    function test_gas_keySets_10() public {
        _measure("10 entries", 10);
    }

    function test_gas_keySets_64() public {
        _measure("64 entries, a full page", 64);
    }

    function _measure(string memory scenario, uint256 count) internal {
        uint256 total;
        uint256 lowest = type(uint256).max;
        uint256 highest;
        uint256 hintedTotal;

        for (uint256 s; s < SETS; ++s) {
            PackedBalances store = stores[s];
            bytes32[] memory keys = _keys(salts[s], count);
            bytes memory hints = store.hintsOf(keys);

            vm.cool(address(store));
            store.bump(keys);
            uint256 used = vm.lastCallGas().gasTotalUsed;

            total += used;
            if (used < lowest) lowest = used;
            if (used > highest) highest = used;

            vm.cool(address(store));
            store.bumpPositional(keys, hints);
            hintedTotal += vm.lastCallGas().gasTotalUsed;

            assertEq(store.balanceOf(keys[0]), 1_002);
        }

        vm.snapshotValue("pagepack-key-sets", scenario, total / SETS);
        vm.snapshotValue("pagepack-key-sets-lowest", scenario, lowest);
        vm.snapshotValue("pagepack-key-sets-highest", scenario, highest);
        vm.snapshotValue("pagepack-key-sets-hinted", scenario, hintedTotal / SETS);
    }

    function _keys(uint256 salt, uint256 count) internal pure returns (bytes32[] memory keys) {
        keys = new bytes32[](count);

        for (uint256 i; i < count; ++i) {
            keys[i] = _key(salt, i);
        }
    }

    function _key(uint256 salt, uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encode("key sets", salt, i));
    }
}
