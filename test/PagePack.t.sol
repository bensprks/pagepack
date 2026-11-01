// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PagePack, Space} from "pagepack/PagePack.sol";
import {RecordStore} from "./utils/RecordStore.sol";

contract PagePackTest is Test {
    RecordStore internal store;

    mapping(uint256 fingerprint => uint256 keyPlusOne) internal seen;

    function setUp() public {
        store = new RecordStore(3);
    }

    // ------------------------------------------------------------------------------------------
    // Lookup
    // ------------------------------------------------------------------------------------------

    function test_unpackedRecordLivesAtHome() public {
        bytes32 key = _key(1);

        _fill(key, 10);

        assertEq(store.slotOf(key), _home(key));
        assertEq(store.hintOf(key), PagePack.HOME);
        assertEq(store.get(key, 0), 10);
        assertEq(store.get(key, 2), 12);
    }

    function test_hintedLookupMatchesDirectoryLookup() public {
        bytes32 key = _key(1);
        _fill(key, 10);
        _pack(key, 7);

        uint256 hint = store.hintOf(key);

        assertEq(hint, 8);
        assertEq(store.slotOf(key, hint), store.slotOf(key));
        assertEq(store.get(key, 1, hint), 11);
    }

    function test_wrongHintsFallBackToDirectory() public {
        bytes32 a = _key(1);
        bytes32 b = _key(2);
        _fill(a, 10);
        _fill(b, 20);
        _pack(a, 0);
        _pack(b, 1);

        uint256 expected = store.slotOf(b);

        // Another record's index, an empty index, an out-of-range index and no hint.
        assertEq(store.slotOf(b, 1), expected);
        assertEq(store.slotOf(b, 500), expected);
        assertEq(store.slotOf(b, type(uint256).max), expected);
        assertEq(store.slotOf(b, 0), expected);
    }

    function test_wrongHintForUnpackedRecordFallsBackToHome() public {
        bytes32 a = _key(1);
        bytes32 b = _key(2);
        _pack(a, 0);

        assertEq(store.slotOf(b, 1), _home(b));
    }

    function test_fingerprintMatchStillChecksIdentity() public {
        (bytes32 a, bytes32 b) = _collidingKeys();
        _fill(a, 10);
        _fill(b, 20);
        _pack(a, 0);

        // b shares a's fingerprint, so the directory points at a's slot. The identity word tells
        // them apart and b resolves to its home.
        assertEq(store.slotOf(b), _home(b));
        assertEq(store.hintOf(b), PagePack.HOME);
        assertEq(store.get(b, 0), 20);
        assertEq(store.get(a, 0), 10);
    }

    function test_fingerprintOfMatchesDirectory() public {
        (bytes32 a, bytes32 b) = _collidingKeys();

        assertEq(store.fingerprintOf(a), _fingerprint(a));
        assertEq(store.fingerprintOf(a), store.fingerprintOf(b));
        assertTrue(store.fingerprintOf(_key(1)) < 1 << 22);
    }

    // ------------------------------------------------------------------------------------------
    // Rebalancing
    // ------------------------------------------------------------------------------------------

    function test_packingMovesDataAndClearsHome() public {
        bytes32 key = _key(1);
        _fill(key, 10);

        _pack(key, 3);

        assertTrue(store.slotOf(key) != _home(key));
        assertEq(store.packedCount(), 1);
        _assertFilled(key, 10);
        _assertHomeEmpty(key);
    }

    function test_evictionRestoresHome() public {
        bytes32 key = _key(1);
        _fill(key, 10);
        _pack(key, 3);
        uint256 packedSlot = store.slotOf(key);

        store.rebalance(_keys(key), _noPlacements());

        assertEq(store.slotOf(key), _home(key));
        assertEq(store.packedCount(), 0);
        _assertFilled(key, 10);

        // Identity and data words of the old packed slot are cleared.
        for (uint256 i; i < 4; ++i) {
            assertEq(uint256(vm.load(address(store), bytes32(packedSlot - 1 + i))), 0);
        }
    }

    function test_moveBetweenPackedSlots() public {
        bytes32 key = _key(1);
        _fill(key, 10);
        _pack(key, 3);

        _pack(key, 40);

        assertEq(store.hintOf(key), 41);
        assertEq(store.packedCount(), 1);
        _assertFilled(key, 10);
    }

    function test_resubmittingLayoutChangesNothing() public {
        PagePack.Placement[] memory placements = new PagePack.Placement[](3);

        for (uint256 i; i < 3; ++i) {
            _fill(_key(i), 10 * i);
            placements[i] = PagePack.Placement(_key(i), i * 5);
        }

        store.rebalance(_noKeys(), placements);
        store.rebalance(_noKeys(), placements);

        assertEq(store.packedCount(), 3);

        for (uint256 i; i < 3; ++i) {
            assertEq(store.hintOf(_key(i)), i * 5 + 1);
            _assertFilled(_key(i), 10 * i);
        }
    }

    function test_slotCanBeReusedAfterEvictionInSameRebalance() public {
        bytes32 a = _key(1);
        bytes32 b = _key(2);
        _fill(a, 10);
        _fill(b, 20);
        _pack(a, 0);

        store.rebalance(_keys(a), _placement(b, 0));

        assertEq(store.hintOf(a), PagePack.HOME);
        assertEq(store.hintOf(b), 1);
        _assertFilled(a, 10);
        _assertFilled(b, 20);
    }

    function test_swapsTwoRecords() public {
        bytes32 a = _key(1);
        bytes32 b = _key(2);
        _fill(a, 10);
        _fill(b, 20);
        _pack(a, 0);
        _pack(b, 1);

        PagePack.Placement[] memory placements = new PagePack.Placement[](2);
        placements[0] = PagePack.Placement(a, 1);
        placements[1] = PagePack.Placement(b, 0);
        store.rebalance(_noKeys(), placements);

        assertEq(store.hintOf(a), 2);
        assertEq(store.hintOf(b), 1);
        assertEq(store.packedCount(), 2);
        _assertFilled(a, 10);
        _assertFilled(b, 20);
    }

    /// a leaves for home, b takes a's index, and c comes from home to take b's.
    function test_cyclesThroughHome() public {
        bytes32 a = _key(1);
        bytes32 b = _key(2);
        bytes32 c = _key(3);
        _fill(a, 10);
        _fill(b, 20);
        _fill(c, 30);
        _pack(a, 0);
        _pack(b, 1);

        PagePack.Placement[] memory placements = new PagePack.Placement[](2);
        placements[0] = PagePack.Placement(c, 1);
        placements[1] = PagePack.Placement(b, 0);
        store.rebalance(_keys(a), placements);

        assertEq(store.hintOf(a), PagePack.HOME);
        assertEq(store.hintOf(b), 1);
        assertEq(store.hintOf(c), 2);
        assertEq(store.packedCount(), 2);
        _assertFilled(a, 10);
        _assertFilled(b, 20);
        _assertFilled(c, 30);
    }

    function test_placementOrderDoesNotMatter() public {
        bytes32 a = _key(1);
        bytes32 b = _key(2);
        _fill(a, 10);
        _fill(b, 20);
        _pack(a, 0);

        // b is listed first but takes the index a only leaves later in the list.
        PagePack.Placement[] memory placements = new PagePack.Placement[](2);
        placements[0] = PagePack.Placement(b, 0);
        placements[1] = PagePack.Placement(a, 5);
        store.rebalance(_noKeys(), placements);

        assertEq(store.hintOf(a), 6);
        assertEq(store.hintOf(b), 1);
        _assertFilled(a, 10);
        _assertFilled(b, 20);
    }

    function test_emptyRebalanceWritesNothing() public {
        _pack(_key(1), 0);

        vm.record();
        store.rebalance(_noKeys(), _noPlacements());

        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(store));
        assertEq(reads.length, 0);
        assertEq(writes.length, 0);
    }

    function test_resubmittedLayoutWritesNothing() public {
        PagePack.Placement[] memory placements = new PagePack.Placement[](3);

        for (uint256 i; i < 3; ++i) {
            _fill(_key(i), 10 * i);
            placements[i] = PagePack.Placement(_key(i), i * 5);
        }

        store.rebalance(_noKeys(), placements);

        vm.record();
        store.rebalance(_noKeys(), placements);

        (, bytes32[] memory writes) = vm.accesses(address(store));
        assertEq(writes.length, 0);
    }

    function test_collisionWithEvictedRecordIsAllowed() public {
        (bytes32 a, bytes32 b) = _collidingKeys();
        _fill(a, 10);
        _fill(b, 20);
        _pack(a, 0);

        store.rebalance(_keys(a), _placement(b, 1));

        assertEq(store.hintOf(a), PagePack.HOME);
        assertEq(store.hintOf(b), 2);
        _assertFilled(a, 10);
        _assertFilled(b, 20);
    }

    function test_revertsWhenIndexTaken() public {
        _pack(_key(1), 0);

        vm.expectRevert(abi.encodeWithSelector(PagePack.IndexTaken.selector, 0));
        store.rebalance(_noKeys(), _placement(_key(2), 0));
    }

    function test_revertsWhenTargetHeldByUnnamedRecord() public {
        bytes32 a = _key(1);
        bytes32 b = _key(2);
        _pack(a, 0);
        _pack(b, 1);

        vm.expectRevert(abi.encodeWithSelector(PagePack.IndexTaken.selector, 0));
        store.rebalance(_noKeys(), _placement(b, 0));
    }

    function test_revertsWhenTwoPlacementsShareIndex() public {
        PagePack.Placement[] memory placements = new PagePack.Placement[](2);
        placements[0] = PagePack.Placement(_key(1), 3);
        placements[1] = PagePack.Placement(_key(2), 3);

        vm.expectRevert(abi.encodeWithSelector(PagePack.IndexTaken.selector, 3));
        store.rebalance(_noKeys(), placements);
    }

    function test_revertsWhenIndexOutOfRange() public {
        uint256 index = PagePack.MAX_INDEX;

        vm.expectRevert(abi.encodeWithSelector(PagePack.IndexOutOfRange.selector, index));
        store.rebalance(_noKeys(), _placement(_key(1), index));
    }

    function test_revertsWhenEvictingUnpackedRecord() public {
        vm.expectRevert(abi.encodeWithSelector(PagePack.NotPacked.selector, _key(1)));
        store.rebalance(_keys(_key(1)), _noPlacements());
    }

    function test_revertsWhenSameKeyPlacedTwice() public {
        PagePack.Placement[] memory placements = new PagePack.Placement[](2);
        placements[0] = PagePack.Placement(_key(1), 0);
        placements[1] = PagePack.Placement(_key(1), 1);

        vm.expectRevert(abi.encodeWithSelector(PagePack.DuplicateKey.selector, _key(1)));
        store.rebalance(_noKeys(), placements);
    }

    function test_revertsWhenPackedKeyNamedTwice() public {
        bytes32 a = _key(1);
        _pack(a, 0);

        bytes32[] memory twice = new bytes32[](2);
        twice[0] = a;
        twice[1] = a;

        vm.expectRevert(abi.encodeWithSelector(PagePack.DuplicateKey.selector, a));
        store.rebalance(twice, _noPlacements());

        vm.expectRevert(abi.encodeWithSelector(PagePack.DuplicateKey.selector, a));
        store.rebalance(_keys(a), _placement(a, 5));

        // Also when one mention leaves the record where it is.
        vm.expectRevert(abi.encodeWithSelector(PagePack.DuplicateKey.selector, a));
        store.rebalance(_keys(a), _placement(a, 0));
    }

    function test_revertsWhenFingerprintsCollide() public {
        (bytes32 a, bytes32 b) = _collidingKeys();
        _pack(a, 0);

        vm.expectRevert(abi.encodeWithSelector(PagePack.FingerprintCollision.selector, b));
        store.rebalance(_noKeys(), _placement(b, 1));
    }

    function test_invalidWidthReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PagePack.InvalidWidth.selector, 0));
        new RecordStore(0);

        vm.expectRevert(abi.encodeWithSelector(PagePack.InvalidWidth.selector, 128));
        new RecordStore(128);
    }

    // ------------------------------------------------------------------------------------------
    // Layout
    // ------------------------------------------------------------------------------------------

    function test_recordsNeverStraddlePages() public {
        // Width 3 plus an identity word: 32 records per page, exactly filling it.
        uint256 perPage = store.recordsPerPage();
        assertEq(perPage, 32);

        PagePack.Placement[] memory placements = new PagePack.Placement[](perPage * 2);

        for (uint256 i; i < placements.length; ++i) {
            placements[i] = PagePack.Placement(_key(i), i);
        }

        store.rebalance(_noKeys(), placements);

        for (uint256 i; i < placements.length; ++i) {
            uint256 first = store.slotOf(_key(i)) - 1;
            uint256 last = first + 3;

            assertEq(first >> 7, last >> 7, "record straddles a page");
            assertEq(first >> 7, (store.slotOf(_key(0)) >> 7) + i / perPage, "wrong page");
        }
    }

    function test_wideRecordsLeaveUnusedTail() public {
        // Width 4 plus an identity word: 25 records per page with 3 slots left over.
        RecordStore wide = new RecordStore(4);
        assertEq(wide.recordsPerPage(), 25);

        PagePack.Placement[] memory placements = new PagePack.Placement[](26);

        for (uint256 i; i < placements.length; ++i) {
            placements[i] = PagePack.Placement(_key(i), i);
        }

        wide.rebalance(_noKeys(), placements);

        uint256 lastOnFirstPage = wide.slotOf(_key(24)) - 1;
        uint256 firstOnSecondPage = wide.slotOf(_key(25)) - 1;

        assertEq(lastOnFirstPage & 127, 120);
        assertEq(firstOnSecondPage & 127, 0);
        assertEq(firstOnSecondPage >> 7, (lastOnFirstPage >> 7) + 1);
    }

    function test_fullDirectory() public {
        store = new RecordStore(1);
        bytes32[] memory keys = _uniqueKeys(PagePack.MAX_PACKED);
        PagePack.Placement[] memory placements = new PagePack.Placement[](keys.length);

        for (uint256 i; i < keys.length; ++i) {
            store.set(keys[i], 0, i + 1);

            // Reverse order exercises the sort.
            placements[i] = PagePack.Placement(keys[i], keys.length - 1 - i);
        }

        store.rebalance(_noKeys(), placements);

        assertEq(store.packedCount(), keys.length);

        for (uint256 i; i < keys.length; ++i) {
            assertEq(store.hintOf(keys[i]), keys.length - i);
            assertEq(store.get(keys[i], 0), i + 1);
        }
    }

    /// Evicts and packs records scattered through a full directory, so the rebuild has to splice
    /// entries into the middle of words as well as copy whole ones.
    function test_rebuildsFullDirectory() public {
        store = new RecordStore(1);
        bytes32[] memory keys = _uniqueKeys(PagePack.MAX_PACKED + 3);
        PagePack.Placement[] memory placements = new PagePack.Placement[](PagePack.MAX_PACKED);

        for (uint256 i; i < keys.length; ++i) {
            store.set(keys[i], 0, i + 1);
        }

        for (uint256 i; i < placements.length; ++i) {
            placements[i] = PagePack.Placement(keys[i], i);
        }

        store.rebalance(_noKeys(), placements);

        bytes32[] memory evictions = new bytes32[](3);
        PagePack.Placement[] memory replacements = new PagePack.Placement[](3);

        for (uint256 i; i < 3; ++i) {
            uint256 victim = 7 + i * 400;
            evictions[i] = keys[victim];
            replacements[i] = PagePack.Placement(keys[PagePack.MAX_PACKED + i], victim);
        }

        store.rebalance(evictions, replacements);

        assertEq(store.packedCount(), PagePack.MAX_PACKED);

        for (uint256 i; i < keys.length; ++i) {
            // Originals keep index i, except the three evicted ones; replacements take theirs.
            uint256 hint = i < PagePack.MAX_PACKED ? i + 1 : 8 + (i - PagePack.MAX_PACKED) * 400;
            if (i >= 7 && i < PagePack.MAX_PACKED && (i - 7) % 400 == 0) hint = PagePack.HOME;

            assertEq(store.hintOf(keys[i]), hint);
            assertEq(store.get(keys[i], 0), i + 1);
        }
    }

    function test_revertsWhenCollisionDeepInDirectory() public {
        store = new RecordStore(1);
        (bytes32 a, bytes32 b) = _collidingKeys();
        bytes32[] memory keys = _uniqueKeys(200);
        PagePack.Placement[] memory placements = new PagePack.Placement[](keys.length + 1);

        for (uint256 i; i < keys.length; ++i) {
            placements[i] = PagePack.Placement(keys[i], i);
        }

        placements[keys.length] = PagePack.Placement(a, keys.length);
        store.rebalance(_noKeys(), placements);

        vm.expectRevert(abi.encodeWithSelector(PagePack.FingerprintCollision.selector, b));
        store.rebalance(_noKeys(), _placement(b, keys.length + 1));
    }

    function test_revertsWhenDirectoryFull() public {
        store = new RecordStore(1);
        bytes32[] memory keys = _uniqueKeys(PagePack.MAX_PACKED + 1);
        PagePack.Placement[] memory placements = new PagePack.Placement[](keys.length);

        for (uint256 i; i < keys.length; ++i) {
            placements[i] = PagePack.Placement(keys[i], i);
        }

        vm.expectRevert(PagePack.DirectoryFull.selector);
        store.rebalance(_noKeys(), placements);
    }

    // ------------------------------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------------------------------

    /// Packs, moves and evicts a random set of records and checks that every value survives and
    /// every record is found where the directory says it is.
    function testFuzz_rebalancePreservesData(uint256 seed) public {
        uint256 n = 24;

        for (uint256 i; i < n; ++i) {
            _fill(_key(i), 100 * (i + 1));
        }

        // Round one: pack a random subset at random distinct indices.
        uint256[] memory indexOf = new uint256[](n);
        bool[] memory taken = new bool[](PagePack.MAX_INDEX);
        PagePack.Placement[] memory first = new PagePack.Placement[](n);
        uint256 firstCount;

        for (uint256 i; i < n; ++i) {
            if (_random(seed, i) % 3 == 0) continue;

            uint256 index = _freeIndex(taken, _random(seed, i + 1000));
            first[firstCount++] = PagePack.Placement(_key(i), index);
            indexOf[i] = index + 1;
        }

        _truncate(first, firstCount);
        store.rebalance(_noKeys(), first);

        // Round two: evict some packed records, move some, and pack some new ones.
        bytes32[] memory evictions = new bytes32[](n);
        PagePack.Placement[] memory second = new PagePack.Placement[](n);
        uint256 evictionCount;
        uint256 secondCount;

        for (uint256 i; i < n; ++i) {
            uint256 roll = _random(seed, i + 2000) % 4;

            if (indexOf[i] != 0 && roll == 0) {
                evictions[evictionCount++] = _key(i);
                indexOf[i] = 0;
            } else if (roll == 1) {
                uint256 index = _freeIndex(taken, _random(seed, i + 3000));
                second[secondCount++] = PagePack.Placement(_key(i), index);
                indexOf[i] = index + 1;
            }
        }

        assembly ("memory-safe") {
            mstore(evictions, evictionCount)
        }
        _truncate(second, secondCount);
        store.rebalance(evictions, second);

        uint256 packed;

        for (uint256 i; i < n; ++i) {
            assertEq(store.hintOf(_key(i)), indexOf[i] == 0 ? PagePack.HOME : indexOf[i]);
            _assertFilled(_key(i), 100 * (i + 1));

            if (indexOf[i] == 0) assertEq(store.slotOf(_key(i)), _home(_key(i)));
            else ++packed;
        }

        assertEq(store.packedCount(), packed);
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    function _key(uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encode("key", i));
    }

    function _identity(bytes32 key) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(store.SPACE(), key)));
    }

    function _home(bytes32 key) internal view returns (uint256) {
        return _identity(key) & ~uint256(127);
    }

    function _fingerprint(bytes32 key) internal view returns (uint256) {
        return _identity(key) >> 234;
    }

    /// Writes value, value + 1, value + 2 into the record's three words.
    function _fill(bytes32 key, uint256 value) internal {
        for (uint256 i; i < 3; ++i) {
            store.set(key, i, value + i);
        }
    }

    function _assertFilled(bytes32 key, uint256 value) internal view {
        for (uint256 i; i < 3; ++i) {
            assertEq(store.get(key, i), value + i);
        }
    }

    function _assertHomeEmpty(bytes32 key) internal view {
        for (uint256 i; i < 3; ++i) {
            assertEq(uint256(vm.load(address(store), bytes32(_home(key) + i))), 0);
        }
    }

    function _pack(bytes32 key, uint256 index) internal {
        store.rebalance(_noKeys(), _placement(key, index));
    }

    function _placement(bytes32 key, uint256 index)
        internal
        pure
        returns (PagePack.Placement[] memory placements)
    {
        placements = new PagePack.Placement[](1);
        placements[0] = PagePack.Placement(key, index);
    }

    function _keys(bytes32 key) internal pure returns (bytes32[] memory keys) {
        keys = new bytes32[](1);
        keys[0] = key;
    }

    function _noKeys() internal pure returns (bytes32[] memory) {}

    function _noPlacements() internal pure returns (PagePack.Placement[] memory) {}

    /// Finds two keys with the same 22-bit fingerprint. A birthday search needs ~2,600 tries.
    function _collidingKeys() internal returns (bytes32 a, bytes32 b) {
        for (uint256 i;; ++i) {
            uint256 fingerprint = _fingerprint(_key(i));
            uint256 previous = seen[fingerprint];

            if (previous != 0) return (_key(previous - 1), _key(i));

            seen[fingerprint] = i + 1;
        }
    }

    /// Returns `count` keys with distinct fingerprints in the current store's space.
    function _uniqueKeys(uint256 count) internal returns (bytes32[] memory keys) {
        keys = new bytes32[](count);
        uint256 found;

        for (uint256 i; found < count; ++i) {
            uint256 fingerprint = _fingerprint(_key(i));
            if (seen[fingerprint] != 0) continue;

            seen[fingerprint] = i + 1;
            keys[found++] = _key(i);
        }
    }

    function _truncate(PagePack.Placement[] memory placements, uint256 length) internal pure {
        assembly ("memory-safe") {
            mstore(placements, length)
        }
    }

    function _freeIndex(bool[] memory taken, uint256 rand) internal pure returns (uint256 index) {
        index = rand % PagePack.MAX_INDEX;

        while (taken[index]) {
            index = (index + 1) % PagePack.MAX_INDEX;
        }

        taken[index] = true;
    }

    function _random(uint256 seed, uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt)));
    }
}
