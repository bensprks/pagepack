// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LibDirectory} from "pagepack/LibDirectory.sol";
import {LibSort} from "pagepack/utils/LibSort.sol";

/// Exposes LibDirectory over one directory, and reads and writes it the slow, obvious way.
contract DirectoryHarness {
    uint256 public constant DIR = uint256(keccak256("pagepack.test.directory")) & ~uint256(127);

    function search(uint256 id) external view returns (bool, uint256, uint256) {
        return LibDirectory.search(DIR, id);
    }

    /// Like {search}, and also returns the gas used around the library call.
    function measureSearch(uint256 id)
        external
        view
        returns (bool found, uint256 index, uint256 position, uint256 gasUsed)
    {
        uint256 start = gasleft();
        (found, index, position) = LibDirectory.search(DIR, id);
        gasUsed = start - gasleft();
    }

    function setIndex(uint256 position, uint256 index) external {
        LibDirectory.setIndex(DIR, position, index);
    }

    function rebuild(uint256[4] memory removed, uint256 removedCount, uint256[] memory insertions)
        external
        returns (bool, uint256, uint256)
    {
        return LibDirectory.rebuild(DIR, removed, removedCount, insertions);
    }

    function put(uint256[] memory entries) external {
        _store(DIR, entries.length);

        for (uint256 i; i < entries.length; ++i) {
            uint256 location = DIR + 1 + i / 8;
            _store(location, _load(location) | (entries[i] << (32 * (i % 8))));
        }
    }

    function entries() external view returns (uint256[] memory list) {
        list = new uint256[](_load(DIR));

        for (uint256 i; i < list.length; ++i) {
            list[i] = (_load(DIR + 1 + i / 8) >> (32 * (i % 8))) & 0xffffffff;
        }
    }

    /// The header and all 127 entry words.
    function words() external view returns (uint256[] memory raw) {
        raw = new uint256[](128);

        for (uint256 i; i < raw.length; ++i) {
            raw[i] = _load(DIR + i);
        }
    }

    function _load(uint256 slot) internal view returns (uint256 value) {
        assembly {
            value := sload(slot)
        }
    }

    function _store(uint256 slot, uint256 value) internal {
        assembly {
            sstore(slot, value)
        }
    }
}

/// `count` random entries with distinct fingerprints, sorted. Duplicates are dropped, so a few
/// may be missing. Sorting test data with LibSort is fine: it has tests of its own.
function randomEntries(uint256 seed, uint256 count) pure returns (uint256[] memory list) {
    list = new uint256[](count);

    for (uint256 i; i < count; ++i) {
        uint256 r = uint256(keccak256(abi.encode(seed, i)));
        list[i] = ((r >> 234) << 10) | (r & 0x3ff);
    }

    LibSort.sort(list);

    uint256 unique;
    for (uint256 i; i < count; ++i) {
        if (unique == 0 || list[i] >> 10 != list[unique - 1] >> 10) list[unique++] = list[i];
    }

    assembly {
        mstore(list, unique)
    }
}
