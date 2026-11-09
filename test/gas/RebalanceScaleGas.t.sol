// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PagePack} from "pagepack/PagePack.sol";
import {EntryStore} from "../utils/EntryStore.sol";

/// Measures rebalancing as the directory fills up. Entries are one slot wide, so 64 share a
/// page, and every entry starts packed at the index matching its key's number. Each test is its
/// own transaction, so every page starts cold.
abstract contract RebalanceScaleGasTest is Test {
    EntryStore internal store;
    bytes32[] internal keys;

    mapping(uint256 fingerprint => bool) internal seen;

    function size() internal pure virtual returns (uint256);

    function group() internal pure virtual returns (string memory);

    function setUp() public {
        store = new EntryStore(1, 0, false);

        // One spare key to swap in. Keys must have distinct fingerprints to be packed together.
        for (uint256 i; keys.length < size() + 1; ++i) {
            bytes32 key = keccak256(abi.encode("scale", i));
            uint256 fingerprint = uint256(keccak256(abi.encode(store.MAP(), key))) >> 234;

            if (seen[fingerprint]) continue;

            seen[fingerprint] = true;
            keys.push(key);
        }

        _seed(store);
        store.rebalance(_layout());
    }

    function test_gas_packAll() public {
        EntryStore fresh = new EntryStore(1, 0, false);
        _seed(fresh);
        PagePack.Placement[] memory placements = _layout();
        vm.cool(address(fresh));

        fresh.rebalance(placements);
        vm.snapshotGasLastCall(group(), "Pack every entry");

        assertEq(fresh.packedCount(), size());
    }

    function test_gas_empty() public {
        store.rebalance(new PagePack.Placement[](0));
        vm.snapshotGasLastCall(group(), "Empty rebalance");
    }

    function test_gas_resubmit() public {
        PagePack.Placement[] memory placements = _layout();

        store.rebalance(placements);
        vm.snapshotGasLastCall(group(), "Resubmit the whole layout");

        assertEq(store.hintOf(keys[size() - 1]), size());
    }

    function test_gas_moveOne() public {
        // Index `size` is free and on another page, so this pays state growth there.
        store.rebalance(_placement(keys[0], size()));
        vm.snapshotGasLastCall(group(), "Move one entry");

        assertEq(store.hintOf(keys[0]), size() + 1);
        assertEq(store.get(keys[0], 0), 1);
    }

    function test_gas_swap() public {
        PagePack.Placement[] memory placements = new PagePack.Placement[](2);
        placements[0] = PagePack.Placement(keys[0], 1);
        placements[1] = PagePack.Placement(keys[1], 0);

        store.rebalance(placements);
        vm.snapshotGasLastCall(group(), "Swap two entries");

        assertEq(store.hintOf(keys[0]), 2);
        assertEq(store.hintOf(keys[1]), 1);
    }

    function test_gas_evict() public {
        store.rebalance(_placement(keys[0], PagePack.HOME));
        vm.snapshotGasLastCall(group(), "Evict one entry");

        assertEq(store.packedCount(), size() - 1);
    }

    function test_gas_replace() public {
        PagePack.Placement[] memory placements = new PagePack.Placement[](2);
        placements[0] = PagePack.Placement(keys[0], PagePack.HOME);
        placements[1] = PagePack.Placement(keys[size()], 0);

        store.rebalance(placements);
        vm.snapshotGasLastCall(group(), "Replace one entry with another");

        assertEq(store.hintOf(keys[size()]), 1);
        assertEq(store.get(keys[size()], 0), size() + 1);
    }

    function _seed(EntryStore target) internal {
        for (uint256 i; i < keys.length; ++i) {
            target.set(keys[i], 0, i + 1);
        }
    }

    function _layout() internal view returns (PagePack.Placement[] memory placements) {
        placements = new PagePack.Placement[](size());

        for (uint256 i; i < placements.length; ++i) {
            placements[i] = PagePack.Placement(keys[i], i);
        }
    }

    function _placement(bytes32 key, uint256 index)
        internal
        pure
        returns (PagePack.Placement[] memory placements)
    {
        placements = new PagePack.Placement[](1);
        placements[0] = PagePack.Placement(key, index);
    }
}

contract RebalanceScaleGas64Test is RebalanceScaleGasTest {
    function size() internal pure override returns (uint256) {
        return 64;
    }

    function group() internal pure override returns (string memory) {
        return "pagepack-rebalance-64";
    }
}

contract RebalanceScaleGas512Test is RebalanceScaleGasTest {
    function size() internal pure override returns (uint256) {
        return 512;
    }

    function group() internal pure override returns (string memory) {
        return "pagepack-rebalance-512";
    }
}

contract RebalanceScaleGas1016Test is RebalanceScaleGasTest {
    function size() internal pure override returns (uint256) {
        return PagePack.MAX_PACKED;
    }

    function group() internal pure override returns (string memory) {
        return "pagepack-rebalance-1016";
    }
}
