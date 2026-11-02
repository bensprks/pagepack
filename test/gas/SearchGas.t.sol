// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DirectoryHarness, randomEntries} from "../utils/DirectoryHarness.sol";

/// Measures the directory search that every lookup without a hint makes, over random
/// directories of each size: 32 directories, each searched for 32 packed entries' fingerprints
/// and 32 others, as for entries at home. Directories differ more than searches within one do,
/// so the sample spans many. The directory page is already loaded, as it is after a
/// transaction's first lookup, so a probe costs a 100 gas read plus the comparisons. Gas is
/// measured around the library call, header read included.
contract SearchGasTest is Test {
    uint256 internal constant DIRECTORIES = 32;
    uint256 internal constant SEARCHES = 32;

    struct Stats {
        uint256 count;
        uint256 probes;
        uint256 maxProbes;
        uint256 gas;
        uint256 maxGas;
    }

    function test_gas_search_64() public {
        _measure(64);
    }

    function test_gas_search_512() public {
        _measure(512);
    }

    function test_gas_search_1016() public {
        _measure(1016);
    }

    function _measure(uint256 size) internal {
        Stats memory packed;
        Stats memory home;

        for (uint256 d; d < DIRECTORIES; ++d) {
            (Stats memory p, Stats memory h) = this.measureDirectory(size, d);

            _add(packed, p);
            _add(home, h);
        }

        string memory directory = string.concat(vm.toString(size), " packed");
        _record(string.concat(directory, ", packed entry"), packed);
        _record(string.concat(directory, ", entry at home"), home);
    }

    /// Searches one random directory. External, so that each directory starts with fresh memory.
    function measureDirectory(uint256 size, uint256 d)
        external
        returns (Stats memory packed, Stats memory home)
    {
        uint256 seed = uint256(keccak256(abi.encode("search", size, d)));
        uint256[] memory list = randomEntries(seed, size);

        DirectoryHarness harness = new DirectoryHarness();
        harness.put(list);
        harness.search(0);

        for (uint256 i; i < SEARCHES; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 entry = list[r % list.length];

            _search(harness, (entry >> 10) << 234, packed, true);

            // A random fingerprint is almost never listed; skip it if it is.
            _search(harness, r << 22, home, false);
        }
    }

    function _search(DirectoryHarness harness, uint256 id, Stats memory stats, bool listed)
        internal
    {
        vm.record();
        (bool found,,, uint256 gasUsed) = harness.measureSearch(id);
        (bytes32[] memory reads,) = vm.accesses(address(harness));

        if (found != listed) {
            assertFalse(listed);
            return;
        }

        // The first read is the header.
        uint256 probes = reads.length - 1;

        stats.count += 1;
        stats.probes += probes;
        stats.gas += gasUsed;
        if (probes > stats.maxProbes) stats.maxProbes = probes;
        if (gasUsed > stats.maxGas) stats.maxGas = gasUsed;
    }

    function _add(Stats memory total, Stats memory stats) internal pure {
        total.count += stats.count;
        total.probes += stats.probes;
        total.gas += stats.gas;
        if (stats.maxProbes > total.maxProbes) total.maxProbes = stats.maxProbes;
        if (stats.maxGas > total.maxGas) total.maxGas = stats.maxGas;
    }

    function _record(string memory scenario, Stats memory stats) internal {
        // Mean probes are kept to two decimals.
        vm.snapshotValue("pagepack-search-probes", scenario, stats.probes * 100 / stats.count);
        vm.snapshotValue("pagepack-search-probes-max", scenario, stats.maxProbes);
        vm.snapshotValue("pagepack-search", scenario, stats.gas / stats.count);
        vm.snapshotValue("pagepack-search-max", scenario, stats.maxGas);
    }
}
