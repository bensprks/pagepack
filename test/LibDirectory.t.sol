// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LibSort} from "../src/utils/LibSort.sol";
import {DirectoryHarness, randomEntries} from "./utils/DirectoryHarness.sol";

/// Checks LibDirectory's assembly against plain Solidity versions of the same operations, over
/// random directories of up to full size.
contract LibDirectoryTest is Test {
    uint256 internal constant NO_TAG = type(uint256).max;

    DirectoryHarness internal harness;

    function setUp() public {
        harness = new DirectoryHarness();
    }

    // ------------------------------------------------------------------------------------------
    // Search
    // ------------------------------------------------------------------------------------------

    function testFuzz_searchFindsEveryEntry(uint256 seed) public {
        uint256[] memory list = randomEntries(seed, _random(seed, "size") % 1017);
        harness.put(list);

        for (uint256 i; i < list.length; ++i) {
            (bool found, uint256 index, uint256 position) = harness.search(_idFor(list[i], seed));

            assertTrue(found);
            assertEq(index, list[i] & 0x3ff);
            assertEq(position, i);
        }
    }

    function testFuzz_searchMissesAbsentFingerprints(uint256 seed) public {
        uint256[] memory list = randomEntries(seed, _random(seed, "size") % 1017);
        harness.put(list);

        for (uint256 i; i < 32; ++i) {
            uint256 fingerprint = _random(seed, i) >> 234;
            if (_contains(list, fingerprint)) continue;

            (bool found,,) = harness.search(fingerprint << 234);
            assertFalse(found);
        }
    }

    function test_searchEmptyDirectory() public view {
        (bool found,,) = harness.search(123 << 234);
        assertFalse(found);
    }

    // ------------------------------------------------------------------------------------------
    // Index updates
    // ------------------------------------------------------------------------------------------

    function testFuzz_setIndexChangesOneEntry(uint256 seed, uint256 position, uint256 index)
        public
    {
        uint256[] memory list = randomEntries(seed, 1 + _random(seed, "size") % 1016);
        harness.put(list);
        position %= list.length;
        index %= 1024;

        harness.setIndex(position, index);

        list[position] = (list[position] & ~uint256(0x3ff)) | index;
        assertEq(harness.entries(), list);
    }

    // ------------------------------------------------------------------------------------------
    // Rebuild
    // ------------------------------------------------------------------------------------------

    /// Removes and inserts random entries, sometimes reusing a fingerprint that is already listed,
    /// removed or being inserted, and compares the result with a plain merge.
    function testFuzz_rebuildMatchesReference(uint256 seed) public {
        uint256[] memory list = randomEntries(seed, _random(seed, "size") % 1017);
        harness.put(list);

        (uint256[4] memory removed, bool[] memory isRemoved, uint256 removedCount) =
            _randomRemovals(seed, list.length);

        uint256 room = 1016 - (list.length - removedCount);
        uint256[] memory insertions = _randomInsertions(seed, list, _random(seed, "k") % 41, room);

        uint256[] memory before = harness.words();
        (bool collided, uint256 tag, uint256 otherTag) =
            harness.rebuild(removed, removedCount, _copy(insertions));

        (uint256[] memory expected, bool clash) = _referenceMerge(list, isRemoved, insertions);
        assertEq(collided, clash, "collision");

        if (collided) {
            // Nothing is written, and each reported insertion really shares its fingerprint.
            assertEq(harness.words(), before);
            assertTrue(tag != NO_TAG || otherTag != NO_TAG);

            if (tag != NO_TAG) {
                assertTrue(_isDuplicated(insertions[tag], list, isRemoved, insertions));
            }
            if (otherTag != NO_TAG) {
                assertTrue(_isDuplicated(insertions[otherTag], list, isRemoved, insertions));
            }

            return;
        }

        assertEq(harness.entries(), expected);

        // Words past the new end are cleared.
        uint256[] memory raw = harness.words();
        for (uint256 w = 1 + (expected.length + 7) / 8; w < raw.length; ++w) {
            assertEq(raw[w], 0);
        }
    }

    function test_rebuildFillsEmptyDirectory() public {
        uint256[] memory insertions = new uint256[](3);
        insertions[0] = _tagged(500, 7, 0);
        insertions[1] = _tagged(2, 1, 1);
        insertions[2] = _tagged(40, 3, 2);

        uint256[4] memory none;
        harness.rebuild(none, 0, insertions);

        uint256[] memory expected = new uint256[](3);
        expected[0] = (2 << 10) | 1;
        expected[1] = (40 << 10) | 3;
        expected[2] = (500 << 10) | 7;
        assertEq(harness.entries(), expected);
    }

    function test_rebuildRemovesEverything() public {
        uint256[] memory list = randomEntries(1, 20);
        harness.put(list);

        uint256[4] memory removed;
        removed[0] = (1 << 20) - 1;
        harness.rebuild(removed, 20, new uint256[](0));

        assertEq(harness.entries().length, 0);

        uint256[] memory raw = harness.words();
        for (uint256 i; i < raw.length; ++i) {
            assertEq(raw[i], 0);
        }
    }

    function test_rebuildReportsDuplicateInsertions() public {
        uint256[] memory insertions = new uint256[](2);
        insertions[0] = _tagged(9, 1, 0);
        insertions[1] = _tagged(9, 2, 1);

        uint256[4] memory none;
        (bool collided, uint256 tag, uint256 otherTag) = harness.rebuild(none, 0, insertions);

        assertTrue(collided);
        assertEq(tag, 1);
        assertEq(otherTag, 0);
    }

    function test_rebuildReportsClashWithStoredEntry() public {
        uint256[] memory list = new uint256[](1);
        list[0] = (9 << 10) | 4;
        harness.put(list);

        uint256[] memory insertions = new uint256[](1);
        insertions[0] = _tagged(9, 5, 0);

        uint256[4] memory none;
        (bool collided, uint256 tag, uint256 otherTag) = harness.rebuild(none, 0, insertions);

        assertTrue(collided);
        assertEq(tag == NO_TAG ? otherTag : tag, 0);
    }

    // ------------------------------------------------------------------------------------------
    // Sort
    // ------------------------------------------------------------------------------------------

    function testFuzz_sortMatchesInsertionSort(uint256[] memory values) public pure {
        uint256[] memory expected = _copy(values);
        _insertionSort(expected);

        LibSort.sort(values);
        assertEq(values, expected);
    }

    function testFuzz_sortHandlesOrderedInput(uint256 seed, uint256 length) public pure {
        length %= 300;
        uint256[] memory values = new uint256[](length);

        for (uint256 i; i < length; ++i) {
            values[i] = _random(seed, i) % 50;
        }

        _insertionSort(values);
        uint256[] memory ascending = _copy(values);
        LibSort.sort(values);
        assertEq(values, ascending);

        // Reversed, with ties.
        for (uint256 i; i < length / 2; ++i) {
            (values[i], values[length - 1 - i]) = (values[length - 1 - i], values[i]);
        }
        LibSort.sort(values);
        assertEq(values, ascending);
    }

    // ------------------------------------------------------------------------------------------
    // Reference implementations and generators
    // ------------------------------------------------------------------------------------------

    /// Kept entries merged with the sorted insertions, and whether any two share a fingerprint.
    function _referenceMerge(
        uint256[] memory list,
        bool[] memory isRemoved,
        uint256[] memory insertions
    ) internal pure returns (uint256[] memory merged, bool clash) {
        uint256[] memory added = new uint256[](insertions.length);
        for (uint256 i; i < added.length; ++i) {
            added[i] = insertions[i] >> 32;
        }
        _insertionSort(added);

        merged = new uint256[](list.length + added.length);
        uint256 count;
        uint256 i;
        uint256 j;

        while (i < list.length || j < added.length) {
            if (i < list.length && isRemoved[i]) {
                ++i;
            } else if (j == added.length || (i < list.length && list[i] < added[j])) {
                merged[count++] = list[i++];
            } else {
                merged[count++] = added[j++];
            }
        }

        assembly {
            mstore(merged, count)
        }

        for (uint256 k = 1; k < count; ++k) {
            if (merged[k] >> 10 == merged[k - 1] >> 10) clash = true;
        }
    }

    function _isDuplicated(
        uint256 insertion,
        uint256[] memory list,
        bool[] memory isRemoved,
        uint256[] memory insertions
    ) internal pure returns (bool) {
        uint256 fingerprint = insertion >> 42;
        uint256 seen;

        for (uint256 i; i < list.length; ++i) {
            if (!isRemoved[i] && list[i] >> 10 == fingerprint) ++seen;
        }

        for (uint256 i; i < insertions.length; ++i) {
            if (insertions[i] >> 42 == fingerprint) ++seen;
        }

        return seen > 1;
    }

    function _randomRemovals(uint256 seed, uint256 length)
        internal
        pure
        returns (uint256[4] memory removed, bool[] memory isRemoved, uint256 count)
    {
        isRemoved = new bool[](length);
        uint256 odds = 1 + _random(seed, "odds") % 8;

        for (uint256 i; i < length; ++i) {
            if (_random(seed, 5000 + i) % odds != 0) continue;

            isRemoved[i] = true;
            removed[i >> 8] |= 1 << (i & 255);
            ++count;
        }
    }

    function _randomInsertions(uint256 seed, uint256[] memory list, uint256 count, uint256 room)
        internal
        pure
        returns (uint256[] memory insertions)
    {
        if (count > room) count = room;
        insertions = new uint256[](count);

        for (uint256 i; i < count; ++i) {
            uint256 r = _random(seed, 10_000 + i);
            uint256 fingerprint = r >> 234;

            // Now and then reuse a listed fingerprint (kept or removed) or an earlier insertion's.
            if (r % 64 == 0 && list.length != 0) fingerprint = list[r % list.length] >> 10;
            if (r % 64 == 1 && i != 0) fingerprint = insertions[(r >> 8) % i] >> 42;

            insertions[i] = _tagged(fingerprint, (r >> 16) & 0x3ff, i);
        }
    }

    function _tagged(uint256 fingerprint, uint256 index, uint256 tag)
        internal
        pure
        returns (uint256)
    {
        return (((fingerprint << 10) | index) << 32) | tag;
    }

    /// An identity whose top 22 bits are the entry's fingerprint.
    function _idFor(uint256 entry, uint256 seed) internal pure returns (uint256) {
        return ((entry >> 10) << 234) | (_random(seed, entry) >> 22);
    }

    function _contains(uint256[] memory list, uint256 fingerprint) internal pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] >> 10 == fingerprint) return true;
        }

        return false;
    }

    function _insertionSort(uint256[] memory a) internal pure {
        for (uint256 i = 1; i < a.length; ++i) {
            uint256 key = a[i];
            uint256 j = i;

            while (j > 0 && a[j - 1] > key) {
                a[j] = a[j - 1];
                --j;
            }

            a[j] = key;
        }
    }

    function _copy(uint256[] memory a) internal pure returns (uint256[] memory b) {
        b = new uint256[](a.length);

        for (uint256 i; i < a.length; ++i) {
            b[i] = a[i];
        }
    }

    function _random(uint256 seed, uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt)));
    }

    function _random(uint256 seed, string memory salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt)));
    }
}
