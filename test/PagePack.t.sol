// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PagePack, PagedMap} from "pagepack/PagePack.sol";
import {EntryStore, EntryStoreBase, KindedEntryStore} from "./utils/EntryStore.sol";

/// Loads hints in one call to the store and looks an entry up in another, as a contract would
/// within one transaction.
contract HintedCaller {
    function loadThenFind(EntryStoreBase store, PagePack.Hint[] calldata hints, bytes32 key)
        external
        returns (uint256)
    {
        store.useHints(hints);
        return store.slotOf(key);
    }
}

/// Creates maps in an external call, so a test can expect the revert.
contract MapFactory {
    function map(uint256 slots, uint256 perPage) external pure returns (PagedMap) {
        return PagePack.map("pagepack.factory", slots).withEntriesPerPage(perPage);
    }

    /// A map of kinds: kind 0 of one slot, and `kind` of `slots`.
    function kinds(uint256 kind, uint256 slots) external pure returns (PagedMap) {
        return PagePack.mapOfKinds("pagepack.factory").withKind(0, 1).withKind(kind, slots).build();
    }

    /// The same, with entries per page set by hand.
    function kinds(uint256 kind, uint256 slots, uint256 perPage) external pure returns (PagedMap) {
        return PagePack.mapOfKinds("pagepack.factory")
            .withKind(0, 1)
            .withKind(kind, slots)
            .build()
            .withEntriesPerPage(perPage);
    }

    function noKinds() external pure returns (PagedMap) {
        return PagePack.mapOfKinds("pagepack.factory").build();
    }

    function requireFits(uint256 kind, uint256 slots) external pure {
        PagePack.mapOfKinds("pagepack.factory")
            .withKind(0, 1)
            .withKind(1, 2)
            .build()
            .requireFits(kind, slots);
    }

    function kindKey(uint256 kind, uint256 value) external pure returns (bytes32) {
        return PagePack.kindKey(kind, value);
    }

    function hashedKindKey(uint256 kind, bytes32 hash) external pure returns (bytes32) {
        return PagePack.hashedKindKey(kind, hash);
    }
}

contract PagePackTest is Test {
    EntryStoreBase internal store;

    mapping(uint256 fingerprint => uint256 keyPlusOne) internal seen;

    function setUp() public {
        store = new EntryStore(3, 0, false);
    }

    // ------------------------------------------------------------------------------------------
    // Lookup
    // ------------------------------------------------------------------------------------------

    function test_unpackedEntryLivesAtHome() public {
        bytes32 key = _key(1);

        _fill(key, 10);

        assertEq(store.slotOf(key), _home(key));
        assertEq(store.hintOf(key), 0);
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

        // Another entry's index, an empty index, an out-of-range index and no hint.
        assertEq(store.slotOf(b, 1), expected);
        assertEq(store.slotOf(b, 500), expected);
        assertEq(store.slotOf(b, type(uint256).max), expected);
        assertEq(store.slotOf(b, 0), expected);
    }

    function test_wrongHintForUnpackedEntryFallsBackToHome() public {
        bytes32 a = _key(1);
        bytes32 b = _key(2);
        _pack(a, 0);

        assertEq(store.slotOf(b, 1), _home(b));
    }

    function test_homeHintSkipsDirectory() public {
        store = new EntryStore(3, 0, true);
        bytes32 key = _key(1);
        _fill(key, 10);
        _pack(_key(2), 0);
        uint256 home = _home(key);

        vm.record();
        assertEq(store.slotOf(key, PagePack.HOME), home);

        // Only the entry's home page is read: the packed flag, not the directory.
        (bytes32[] memory reads,) = vm.accesses(address(store));
        assertEq(reads.length, 1);
        assertEq(uint256(reads[0]), home + 127);

        assertEq(store.get(key, 1, PagePack.HOME), 11);
    }

    function test_homeHintForPackedEntryFallsBackToDirectory() public {
        store = new EntryStore(3, 0, true);
        bytes32 key = _key(1);
        _fill(key, 10);
        _pack(key, 4);

        assertEq(store.slotOf(key, PagePack.HOME), store.slotOf(key));
        assertEq(store.get(key, 2, PagePack.HOME), 12);
    }

    function test_packedFlagFollowsEntry() public {
        store = new EntryStore(3, 0, true);
        bytes32 key = _key(1);
        _fill(key, 10);
        assertEq(_flag(key), 0);

        _pack(key, 4);
        assertEq(_flag(key), 1);

        // Moving between packed slots leaves it set.
        _pack(key, 9);
        assertEq(_flag(key), 1);

        store.rebalance(_eviction(key));
        assertEq(_flag(key), 0);
        assertEq(store.slotOf(key, PagePack.HOME), _home(key));
        _assertFilled(key, 10);
    }

    function test_defaultMapKeepsNoFlagsAndIgnoresHomeHints() public {
        bytes32 a = _key(1);
        bytes32 b = _key(2);
        _fill(a, 10);
        _fill(b, 20);
        _pack(a, 4);

        assertEq(_flag(a), 0);
        assertEq(store.hintOf(b), 0);

        // HOME is just another wrong hint here: both lookups still find the right entry.
        assertEq(store.slotOf(a, PagePack.HOME), store.slotOf(a));
        assertEq(store.slotOf(b, PagePack.HOME), _home(b));

        store.rebalance(_eviction(a));
        assertEq(_flag(a), 0);
        _assertFilled(a, 10);
    }

    function test_homeHintMapsHaveTheirOwnStorage() public {
        EntryStore plain = new EntryStore(3, 0, false);
        EntryStore hinted = new EntryStore(3, 0, true);
        uint256 plainMap = uint256(PagedMap.unwrap(plain.MAP()));
        uint256 hintedMap = uint256(PagedMap.unwrap(hinted.MAP()));

        // Same name and width; only the mode bit differs, which moves every slot.
        assertEq((plainMap >> 16) & 0xff, 3);
        assertEq((hintedMap >> 16) & 0xff, 3);
        assertEq(plainMap ^ hintedMap, 0x80);
        assertEq(plain.entriesPerPage(), hinted.entriesPerPage());
    }

    function test_widestEntriesLeaveRoomForFlag() public {
        uint256 slots = PagePack.MAX_WIDTH;
        EntryStore widest = new EntryStore(slots, 0, true);
        bytes32 key = _key(1);

        for (uint256 i; i < slots; ++i) {
            widest.set(key, i, i + 1);
        }

        widest.rebalance(_placement(key, 0));
        widest.rebalance(_eviction(key));

        for (uint256 i; i < slots; ++i) {
            assertEq(widest.get(key, i, PagePack.HOME), i + 1);
        }

        uint256 home = uint256(keccak256(abi.encode(widest.MAP(), key))) & ~uint256(127);
        assertEq(uint256(vm.load(address(widest), bytes32(home + 127))), 0);
    }

    function test_loadedHintSkipsDirectory() public {
        bytes32 key = _key(1);
        _fill(key, 10);
        _pack(key, 3);
        uint256 expected = store.slotOf(key);
        PagePack.Hint[] memory hints = _hint(key, 4);

        vm.record();
        assertEq(store.slotOfWithHints(hints, key), expected);

        (bytes32[] memory reads,) = vm.accesses(address(store));
        _assertNotRead(reads, _directory());
    }

    function test_loadedHintsLastForTheTransaction() public {
        bytes32 key = _key(1);
        _fill(key, 10);
        _pack(key, 3);
        uint256 expected = store.slotOf(key);

        // Foundry gives each top-level test call fresh transient storage, so a helper makes both
        // calls inside one.
        HintedCaller caller = new HintedCaller();

        vm.record();
        assertEq(caller.loadThenFind(store, _hint(key, 4), key), expected);

        (bytes32[] memory reads,) = vm.accesses(address(store));
        _assertNotRead(reads, _directory());
    }

    function test_wrongLoadedHintsFallBackToDirectory() public {
        bytes32 a = _key(1);
        bytes32 b = _key(2);
        _fill(a, 10);
        _fill(b, 20);
        _pack(a, 0);
        _pack(b, 1);

        // Another entry's index, an empty index, HOME for a packed entry, and a packed index
        // for an entry that isn't packed.
        assertEq(store.slotOfWithHints(_hint(b, 1), b), store.slotOf(b, 2));
        assertEq(store.slotOfWithHints(_hint(b, 500), b), store.slotOf(b, 2));
        assertEq(store.slotOfWithHints(_hint(b, PagePack.HOME), b), store.slotOf(b, 2));
        assertEq(store.slotOfWithHints(_hint(_key(3), 1), _key(3)), _home(_key(3)));
    }

    function test_fingerprintMatchStillChecksIdentity() public {
        (bytes32 a, bytes32 b) = _collidingKeys();
        _fill(a, 10);
        _fill(b, 20);
        _pack(a, 0);

        // b shares a's fingerprint, so the directory points at a's index. The tag tells them
        // apart and b resolves to its home.
        assertEq(store.slotOf(b), _home(b));
        assertEq(store.hintOf(b), 0);
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

        store.rebalance(_eviction(key));

        assertEq(store.slotOf(key), _home(key));
        assertEq(store.packedCount(), 0);
        _assertFilled(key, 10);

        // The old index's tag and data slots are cleared.
        assertEq(_load(_tagSlot(3)), 0);

        for (uint256 i; i < 3; ++i) {
            assertEq(_load(packedSlot + i), 0);
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

        store.rebalance(placements);
        store.rebalance(placements);

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

        store.rebalance(_join(_eviction(a), _placement(b, 0)));

        assertEq(store.hintOf(a), 0);
        assertEq(store.hintOf(b), 1);
        _assertFilled(a, 10);
        _assertFilled(b, 20);
    }

    function test_swapsTwoEntries() public {
        bytes32 a = _key(1);
        bytes32 b = _key(2);
        _fill(a, 10);
        _fill(b, 20);
        _pack(a, 0);
        _pack(b, 1);

        PagePack.Placement[] memory placements = new PagePack.Placement[](2);
        placements[0] = PagePack.Placement(a, 1);
        placements[1] = PagePack.Placement(b, 0);
        store.rebalance(placements);

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
        store.rebalance(_join(_eviction(a), placements));

        assertEq(store.hintOf(a), 0);
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
        store.rebalance(placements);

        assertEq(store.hintOf(a), 6);
        assertEq(store.hintOf(b), 1);
        _assertFilled(a, 10);
        _assertFilled(b, 20);
    }

    function test_emptyRebalanceWritesNothing() public {
        _pack(_key(1), 0);

        vm.record();
        store.rebalance(_noPlacements());

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

        store.rebalance(placements);

        vm.record();
        store.rebalance(placements);

        (, bytes32[] memory writes) = vm.accesses(address(store));
        assertEq(writes.length, 0);
    }

    function test_collisionWithEvictedEntryIsAllowed() public {
        (bytes32 a, bytes32 b) = _collidingKeys();
        _fill(a, 10);
        _fill(b, 20);
        _pack(a, 0);

        store.rebalance(_join(_eviction(a), _placement(b, 1)));

        assertEq(store.hintOf(a), 0);
        assertEq(store.hintOf(b), 2);
        _assertFilled(a, 10);
        _assertFilled(b, 20);
    }

    function test_revertsWhenIndexTaken() public {
        _pack(_key(1), 0);

        vm.expectRevert(abi.encodeWithSelector(PagePack.IndexTaken.selector, 0));
        store.rebalance(_placement(_key(2), 0));
    }

    function test_revertsWhenTargetHeldByUnnamedEntry() public {
        bytes32 a = _key(1);
        bytes32 b = _key(2);
        _pack(a, 0);
        _pack(b, 1);

        vm.expectRevert(abi.encodeWithSelector(PagePack.IndexTaken.selector, 0));
        store.rebalance(_placement(b, 0));
    }

    function test_revertsWhenTwoPlacementsShareIndex() public {
        PagePack.Placement[] memory placements = new PagePack.Placement[](2);
        placements[0] = PagePack.Placement(_key(1), 3);
        placements[1] = PagePack.Placement(_key(2), 3);

        vm.expectRevert(abi.encodeWithSelector(PagePack.IndexTaken.selector, 3));
        store.rebalance(placements);
    }

    function test_revertsWhenIndexOutOfRange() public {
        uint256 index = PagePack.MAX_INDEX;

        vm.expectRevert(abi.encodeWithSelector(PagePack.IndexOutOfRange.selector, index));
        store.rebalance(_placement(_key(1), index));
    }

    function test_revertsWhenEvictingUnpackedEntry() public {
        vm.expectRevert(abi.encodeWithSelector(PagePack.NotPacked.selector, _key(1)));
        store.rebalance(_eviction(_key(1)));
    }

    function test_revertsWhenSameKeyPlacedTwice() public {
        PagePack.Placement[] memory placements = new PagePack.Placement[](2);
        placements[0] = PagePack.Placement(_key(1), 0);
        placements[1] = PagePack.Placement(_key(1), 1);

        vm.expectRevert(abi.encodeWithSelector(PagePack.DuplicateKey.selector, _key(1)));
        store.rebalance(placements);
    }

    function test_revertsWhenPackedKeyNamedTwice() public {
        bytes32 a = _key(1);
        _pack(a, 0);

        vm.expectRevert(abi.encodeWithSelector(PagePack.DuplicateKey.selector, a));
        store.rebalance(_join(_eviction(a), _eviction(a)));

        vm.expectRevert(abi.encodeWithSelector(PagePack.DuplicateKey.selector, a));
        store.rebalance(_join(_eviction(a), _placement(a, 5)));

        // Also when one mention leaves the entry where it is.
        vm.expectRevert(abi.encodeWithSelector(PagePack.DuplicateKey.selector, a));
        store.rebalance(_join(_eviction(a), _placement(a, 0)));
    }

    /// The new entry sorts after the existing one when its index is higher, and before it when
    /// lower. Both must name b as a collision, not as a duplicate.
    function test_revertsWhenFingerprintsCollide() public {
        (bytes32 a, bytes32 b) = _collidingKeys();
        _pack(a, 1);

        vm.expectRevert(abi.encodeWithSelector(PagePack.FingerprintCollision.selector, b));
        store.rebalance(_placement(b, 2));

        vm.expectRevert(abi.encodeWithSelector(PagePack.FingerprintCollision.selector, b));
        store.rebalance(_placement(b, 0));
    }

    function test_invalidWidthReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PagePack.InvalidWidth.selector, 0));
        new EntryStore(0, 0, false);

        vm.expectRevert(abi.encodeWithSelector(PagePack.InvalidWidth.selector, 128));
        new EntryStore(128, 0, false);
    }

    // ------------------------------------------------------------------------------------------
    // Layout
    // ------------------------------------------------------------------------------------------

    function test_entriesNeverStraddlePages() public {
        // Width 3 and a tag each: 32 entries per page, exactly filling it.
        uint256 perPage = store.entriesPerPage();
        assertEq(perPage, 32);

        PagePack.Placement[] memory placements = new PagePack.Placement[](perPage * 2);

        for (uint256 i; i < placements.length; ++i) {
            placements[i] = PagePack.Placement(_key(i), i);
        }

        store.rebalance(placements);

        for (uint256 i; i < placements.length; ++i) {
            uint256 first = store.slotOf(_key(i));
            uint256 last = first + 2;

            assertEq(first >> 7, last >> 7, "entry straddles a page");
            assertEq(first >> 7, _tagSlot(i) >> 7, "data and tag on different pages");
            assertEq(first >> 7, (store.slotOf(_key(0)) >> 7) + i / perPage, "wrong page");
            assertGe(first & 127, perPage, "data in the tag region");
        }
    }

    function test_wideEntriesLeaveUnusedTail() public {
        // Width 4 and a tag each: 25 entries per page with 3 slots left over.
        EntryStore wide = new EntryStore(4, 0, false);
        assertEq(wide.entriesPerPage(), 25);

        PagePack.Placement[] memory placements = new PagePack.Placement[](26);

        for (uint256 i; i < placements.length; ++i) {
            placements[i] = PagePack.Placement(_key(i), i);
        }

        wide.rebalance(placements);

        uint256 lastOnFirstPage = wide.slotOf(_key(24));
        uint256 firstOnSecondPage = wide.slotOf(_key(25));

        // Tags take slots 0 to 24, so data starts at 25 and the last entry ends at 124.
        assertEq(lastOnFirstPage & 127, 121);
        assertEq(firstOnSecondPage & 127, 25);
        assertEq(firstOnSecondPage >> 7, (lastOnFirstPage >> 7) + 1);
    }

    function test_fullDirectory() public {
        store = new EntryStore(1, 0, false);
        bytes32[] memory keys = _uniqueKeys(PagePack.MAX_PACKED);
        PagePack.Placement[] memory placements = new PagePack.Placement[](keys.length);

        for (uint256 i; i < keys.length; ++i) {
            store.set(keys[i], 0, i + 1);

            // Reverse order exercises the sort.
            placements[i] = PagePack.Placement(keys[i], keys.length - 1 - i);
        }

        store.rebalance(placements);

        assertEq(store.packedCount(), keys.length);

        for (uint256 i; i < keys.length; ++i) {
            assertEq(store.hintOf(keys[i]), keys.length - i);
            assertEq(store.get(keys[i], 0), i + 1);
        }
    }

    /// Evicts and packs entries scattered through a full directory, so the rebuild has to splice
    /// entries into the middle of words as well as copy whole ones.
    function test_rebuildsFullDirectory() public {
        store = new EntryStore(1, 0, false);
        bytes32[] memory keys = _uniqueKeys(PagePack.MAX_PACKED + 3);
        PagePack.Placement[] memory placements = new PagePack.Placement[](PagePack.MAX_PACKED);

        for (uint256 i; i < keys.length; ++i) {
            store.set(keys[i], 0, i + 1);
        }

        for (uint256 i; i < placements.length; ++i) {
            placements[i] = PagePack.Placement(keys[i], i);
        }

        store.rebalance(placements);

        PagePack.Placement[] memory replacements = new PagePack.Placement[](6);

        for (uint256 i; i < 3; ++i) {
            uint256 victim = 7 + i * 400;
            replacements[i] = PagePack.Placement(keys[victim], PagePack.HOME);
            replacements[3 + i] = PagePack.Placement(keys[PagePack.MAX_PACKED + i], victim);
        }

        store.rebalance(replacements);

        assertEq(store.packedCount(), PagePack.MAX_PACKED);

        for (uint256 i; i < keys.length; ++i) {
            // Originals keep index i, except the three evicted ones; replacements take theirs.
            uint256 hint = i < PagePack.MAX_PACKED ? i + 1 : 8 + (i - PagePack.MAX_PACKED) * 400;
            if (i >= 7 && i < PagePack.MAX_PACKED && (i - 7) % 400 == 0) hint = 0;

            assertEq(store.hintOf(keys[i]), hint);
            assertEq(store.get(keys[i], 0), i + 1);
        }
    }

    function test_revertsWhenCollisionDeepInDirectory() public {
        store = new EntryStore(1, 0, false);
        (bytes32 a, bytes32 b) = _collidingKeys();
        bytes32[] memory keys = _uniqueKeys(200);
        PagePack.Placement[] memory placements = new PagePack.Placement[](keys.length + 1);

        for (uint256 i; i < keys.length; ++i) {
            placements[i] = PagePack.Placement(keys[i], i);
        }

        placements[keys.length] = PagePack.Placement(a, 250);
        store.rebalance(placements);

        // Above and below a's index.
        vm.expectRevert(abi.encodeWithSelector(PagePack.FingerprintCollision.selector, b));
        store.rebalance(_placement(b, 251));

        vm.expectRevert(abi.encodeWithSelector(PagePack.FingerprintCollision.selector, b));
        store.rebalance(_placement(b, 201));
    }

    function test_revertsWhenDirectoryFull() public {
        store = new EntryStore(1, 0, false);
        bytes32[] memory keys = _uniqueKeys(PagePack.MAX_PACKED + 1);
        PagePack.Placement[] memory placements = new PagePack.Placement[](keys.length);

        for (uint256 i; i < keys.length; ++i) {
            placements[i] = PagePack.Placement(keys[i], i);
        }

        vm.expectRevert(PagePack.DirectoryFull.selector);
        store.rebalance(placements);
    }

    // ------------------------------------------------------------------------------------------
    // Kinds
    // ------------------------------------------------------------------------------------------

    function test_pagesFitTheirEntriesAtEverySize() public pure {
        for (uint256 slots = 1; slots <= PagePack.MAX_WIDTH; ++slots) {
            PagedMap m = PagePack.map("x", slots);
            uint256 perPage = m.entriesPerPage();

            // As many entries as fit, each with a tag, and the rest of the page for data.
            assertLe(perPage * (slots + 1), 128);
            assertGt((perPage + 1) * (slots + 1), 128);
            assertEq(m.dataSlotsPerPage(), 128 - perPage);
        }
    }

    function test_handleListsItsKinds() public pure {
        PagedMap m = PagePack.mapOfKinds("x").withKind(0, 1).withKind(1, 2).build();
        uint256 handle = uint256(PagedMap.unwrap(m));

        // Flags (a map of kinds), entries per page, then a byte per kind.
        assertEq(handle & 0xff, 0x40);
        assertEq((handle >> 8) & 0xff, 50);
        assertEq((handle >> 16) & 0xffffffffffffffff, 0x0201);
        assertEq(m.slotsOf(0), 1);
        assertEq(m.slotsOf(1), 2);
        assertEq(m.slotsOf(2), 0);
        assertEq(m.slotsOf(300), 0);

        // The order kinds are listed in doesn't matter.
        PagedMap other = PagePack.mapOfKinds("x").withKind(1, 2).withKind(0, 1).build();
        assertEq(PagedMap.unwrap(other), PagedMap.unwrap(m));

        // A map of one kind keeps its width as kind 0's, and has its own storage.
        uint256 one = uint256(PagedMap.unwrap(PagePack.map("x", 3)));
        assertEq(one & 0xffff, 32 << 8);
        assertEq((one >> 16) & 0xffffffffffffffff, 3);
        assertEq(one >> 80, handle >> 80);
    }

    function test_keysKindSetsItsEntrysSize() public {
        store = _kinded(1, 2);
        (bytes32 a, bytes32 b) = (_key(0, 1), _key(1, 1));

        assertEq(store.sizeOf(a), 1);
        assertEq(store.sizeOf(b), 2);

        // The kind is part of the key, so these are two entries.
        store.set(a, 0, 10);
        store.set(b, 0, 20);
        assertTrue(_home(a) != _home(b));
        assertEq(store.get(a, 0), 10);
        assertEq(store.get(b, 0), 20);

        // In a map of one kind the top byte is only part of the key.
        store = new EntryStore(3, 0, false);
        assertEq(store.sizeOf(_key(5, 1)), 3);
        assertEq(store.sizeOf(_key(200, 1)), 3);
    }

    function test_unknownKindCannotBePacked() public {
        store = _kinded(1, 2);

        vm.expectRevert(abi.encodeWithSelector(PagePack.UnknownKind.selector, 2));
        store.sizeOf(_key(2, 1));

        vm.expectRevert(abi.encodeWithSelector(PagePack.UnknownKind.selector, 2));
        store.rebalance(_placement(_key(2, 1), 0));

        vm.expectRevert(abi.encodeWithSelector(PagePack.UnknownKind.selector, 200));
        store.rebalance(_placement(_key(200, 1), 0));

        // Evicting one fails the same way, since it could never have been packed.
        vm.expectRevert(abi.encodeWithSelector(PagePack.UnknownKind.selector, 2));
        store.rebalance(_eviction(_key(2, 1)));

        // It can still be read and written at home, like any entry that isn't packed.
        store.set(_key(2, 1), 0, 7);
        assertEq(store.get(_key(2, 1), 0), 7);
        assertEq(store.slotOf(_key(2, 1)), _home(_key(2, 1)));
    }

    function test_kindsMustBeNewAndInRange() public {
        MapFactory factory = new MapFactory();

        factory.kinds(7, 3);

        vm.expectRevert(abi.encodeWithSelector(PagePack.InvalidKind.selector, 8));
        factory.kinds(8, 3);

        // Kind 0 is already listed.
        vm.expectRevert(abi.encodeWithSelector(PagePack.InvalidKind.selector, 0));
        factory.kinds(0, 3);

        vm.expectRevert(abi.encodeWithSelector(PagePack.InvalidWidth.selector, 0));
        factory.kinds(1, 0);

        vm.expectRevert(abi.encodeWithSelector(PagePack.InvalidWidth.selector, 128));
        factory.kinds(1, 128);

        // A map needs a kind.
        vm.expectRevert(PagePack.NoKinds.selector);
        factory.noKinds();

        // With entries per page set by hand, every kind has to fit the data slots left.
        factory.kinds(1, 64, 64);

        vm.expectRevert(abi.encodeWithSelector(PagePack.InvalidEntriesPerPage.selector, 64));
        factory.kinds(1, 65, 64);
    }

    function test_structsAreCheckedAgainstTheirKind() public {
        MapFactory factory = new MapFactory();

        factory.requireFits(0, 1);
        factory.requireFits(1, 2);
        factory.requireFits(1, 1);

        vm.expectRevert(abi.encodeWithSelector(PagePack.StructTooWide.selector, 2, 1));
        factory.requireFits(0, 2);

        // A kind the map doesn't list fits nothing.
        vm.expectRevert(abi.encodeWithSelector(PagePack.StructTooWide.selector, 1, 0));
        factory.requireFits(2, 1);
    }

    // ------------------------------------------------------------------------------------------
    // Keys
    // ------------------------------------------------------------------------------------------

    function test_kindKeysKeepTheirInputOutOfTheKind() public {
        MapFactory factory = new MapFactory();

        assertEq(factory.kindKey(1, 7), bytes32((uint256(1) << 248) | 7));
        assertEq(factory.kindKey(0, type(uint248).max), bytes32(uint256(type(uint248).max)));
        assertEq(factory.kindKey(255, 0), bytes32(uint256(255) << 248));

        // A value that reaches the top byte would name another kind's entry. It is refused, not
        // cut short, which would make two values share an entry.
        uint256 crafted = (uint256(1) << 248) | 7;
        vm.expectRevert(abi.encodeWithSelector(PagePack.KeyTooLong.selector, crafted));
        factory.kindKey(0, crafted);

        // A hash keeps its first 31 bytes, whatever its top byte was.
        bytes32 hash = bytes32(type(uint256).max);
        assertEq(
            factory.hashedKindKey(1, hash), bytes32((uint256(1) << 248) | (type(uint256).max >> 8))
        );
        assertEq(uint256(factory.hashedKindKey(0, hash)) >> 248, 0);
    }

    /// What the key functions prevent: a key whose top byte came from input reaches another
    /// kind's entry, and writing a wider struct's second slot through it overwrites the packed
    /// entry next to it.
    function test_keyBuiltByHandFromInputReachesAnotherKind() public {
        // Kind 0 is two slots, kind 1 is one.
        store = _kinded(2, 1);
        (bytes32 victim, bytes32 neighbour) =
            (bytes32((uint256(1) << 248) | 7), bytes32((uint256(1) << 248) | 8));
        store.set(victim, 0, 111);
        store.set(neighbour, 0, 222);

        // A getter for kind 0 that ORs an id from input under its kind.
        uint256 id = (uint256(1) << 248) | 7;
        bytes32 byHand = bytes32((uint256(0) << 248) | id);
        assertEq(byHand, victim);
        assertEq(store.sizeOf(byHand), 1);

        PagePack.Placement[] memory placements = new PagePack.Placement[](2);
        placements[0] = PagePack.Placement(victim, 0);
        placements[1] = PagePack.Placement(neighbour, 1);
        store.rebalance(placements);

        // The second slot of the two-slot struct lands on the neighbour.
        store.set(byHand, 1, 666);
        assertEq(store.get(neighbour, 0), 666);
    }

    function test_entriesOfSeveralSizesShareAPage() public {
        store = _kinded(1, 2, 3);
        (bytes32 a, bytes32 b, bytes32 c) = (_key(1, 1), _key(0, 2), _key(2, 3));
        _fillAll(a, 10);
        _fillAll(b, 20);
        _fillAll(c, 30);

        PagePack.Placement[] memory placements = new PagePack.Placement[](3);
        placements[0] = PagePack.Placement(a, 0);
        placements[1] = PagePack.Placement(b, 1);
        placements[2] = PagePack.Placement(c, 2);
        store.rebalance(placements);

        // Data follows the page's tags, in placement order, each entry as long as its size.
        uint256 data = _directory() + 128 + store.entriesPerPage();
        assertEq(store.entriesPerPage(), 42);
        assertEq(store.slotOf(a), data);
        assertEq(store.slotOf(b), data + 2);
        assertEq(store.slotOf(c), data + 3);
        assertEq(store.packedCount(), 3);

        _assertAll(a, 10);
        _assertAll(b, 20);
        _assertAll(c, 30);
    }

    function test_hintsArePlainIndicesForEveryKind() public {
        store = _kinded(1, 2);
        (bytes32 a, bytes32 b) = (_key(1, 1), _key(0, 2));
        _fillAll(a, 10);
        _fillAll(b, 20);

        PagePack.Placement[] memory placements = new PagePack.Placement[](2);
        placements[0] = PagePack.Placement(a, 5);
        placements[1] = PagePack.Placement(b, 6);
        store.rebalance(placements);

        assertEq(store.hintOf(a), 6);
        assertEq(store.hintOf(b), 7);
        assertEq(store.hintOf(_key(1, 3)), 0);

        uint256 expected = store.slotOf(a);
        assertEq(store.slotOf(a, 6), expected);

        // For another key, it is only a wrong hint.
        assertEq(store.slotOf(_key(1, 3), 6), _home(_key(1, 3)));

        // Hints for both kinds load from one list, and the lookup then reads only the tag.
        PagePack.Hint[] memory hints = new PagePack.Hint[](2);
        hints[0] = PagePack.Hint(a, 6);
        hints[1] = PagePack.Hint(b, 7);

        vm.record();
        assertEq(store.slotOfWithHints(hints, a), expected);

        (bytes32[] memory reads,) = vm.accesses(address(store));
        assertEq(reads.length, 1);
        assertEq(uint256(reads[0]), _directory() + 128 + 5);
    }

    function test_movingWithinAPageMovesOnlyTags() public {
        store = _kinded(1, 2);
        (bytes32 a, bytes32 b) = (_key(1, 1), _key(0, 2));
        _fillAll(a, 10);
        _fillAll(b, 20);

        PagePack.Placement[] memory placements = new PagePack.Placement[](2);
        placements[0] = PagePack.Placement(a, 0);
        placements[1] = PagePack.Placement(b, 1);
        store.rebalance(placements);

        uint256 slotA = store.slotOf(a);
        uint256 slotB = store.slotOf(b);

        // a takes b's index and b moves to a free one.
        placements[0].index = 1;
        placements[1].index = 2;

        vm.record();
        store.rebalance(placements);
        (, bytes32[] memory writes) = vm.accesses(address(store));

        // On the packed page, only tags are written.
        uint256 start = _directory() + 128;

        for (uint256 i; i < writes.length; ++i) {
            if (uint256(writes[i]) >= start) {
                assertLt(uint256(writes[i]), start + store.entriesPerPage(), "data");
            }
        }

        assertEq(store.slotOf(a), slotA);
        assertEq(store.slotOf(b), slotB);
        assertEq(store.hintOf(a), 2);
        assertEq(store.hintOf(b), 3);
        _assertAll(a, 10);
        _assertAll(b, 20);
    }

    /// Fills a page, frees two one-slot gaps and packs a two-slot entry: the staying entries
    /// slide together to make room, keeping their indices.
    function test_compactsAPageToFitAnEntry() public {
        // Kinds of 1, 30, 32 and 2 slots, on pages of 64 tags and 64 data slots.
        uint256[] memory sizes = new uint256[](4);
        (sizes[0], sizes[1], sizes[2], sizes[3]) = (1, 30, 32, 2);
        store = new KindedEntryStore(sizes, 64, false);

        bytes32[5] memory keys = [_key(0, 1), _key(1, 2), _key(0, 3), _key(2, 4), _key(3, 5)];

        for (uint256 i; i < 5; ++i) {
            _fillAll(keys[i], 100 * (i + 1));
        }

        // 1 + 30 + 1 + 32 slots fill the page's 64 data slots.
        PagePack.Placement[] memory placements = new PagePack.Placement[](4);

        for (uint256 i; i < 4; ++i) {
            placements[i] = PagePack.Placement(keys[i], i);
        }

        store.rebalance(placements);

        uint256 start = _directory() + 128;
        assertEq(store.slotOf(keys[3]), start + 96);

        placements = new PagePack.Placement[](3);
        placements[0] = PagePack.Placement(keys[0], PagePack.HOME);
        placements[1] = PagePack.Placement(keys[2], PagePack.HOME);
        placements[2] = PagePack.Placement(keys[4], 4);
        store.rebalance(placements);

        assertEq(store.slotOf(keys[1]), start + 64);
        assertEq(store.slotOf(keys[3]), start + 94);
        assertEq(store.slotOf(keys[4]), start + 126);

        // Moving data doesn't move indices, so hints stay valid.
        assertEq(store.hintOf(keys[1]), 2);
        assertEq(store.hintOf(keys[3]), 4);
        assertEq(store.packedCount(), 3);

        for (uint256 i; i < 5; ++i) {
            _assertAll(keys[i], 100 * (i + 1));
        }
    }

    function test_revertsWhenPageFull() public {
        uint256[] memory sizes = new uint256[](2);
        (sizes[0], sizes[1]) = (1, 64);
        store = new KindedEntryStore(sizes, 64, false);

        // A 64-slot entry fills the page's data region, leaving 63 indices without room.
        store.rebalance(_placement(_key(1, 1), 0));

        vm.expectRevert(abi.encodeWithSelector(PagePack.PageFull.selector, 0));
        store.rebalance(_placement(_key(0, 2), 1));

        // The next page has room.
        store.rebalance(_placement(_key(0, 2), 64));
        assertEq(store.hintOf(_key(0, 2)), 65);
    }

    /// An attacker owns entry x, packed next to a victim's entry v, and writes into x a word
    /// shaped like a tag for another of their keys, y, pointing at v's data. Lookups read tags
    /// only from the tag region, so no hint and no directory search ever reaches that word.
    function test_dataShapedLikeATagNeverResolves() public {
        store = new EntryStore(1, 0, false);
        (bytes32 x, bytes32 v, bytes32 y) = (_key(1), _key(2), _key(3));

        PagePack.Placement[] memory placements = new PagePack.Placement[](2);
        placements[0] = PagePack.Placement(x, 0);
        placements[1] = PagePack.Placement(v, 1);
        store.rebalance(placements);

        uint256 victim = store.slotOf(v) - (_directory() + 128);
        store.set(x, 0, (_identity(y) >> 14 << 14) | (victim << 7) | 1);

        assertEq(store.slotOf(y), _home(y));

        for (uint256 hint = 1; hint <= PagePack.HOME; ++hint) {
            assertEq(store.slotOf(y, hint), _home(y));
        }
    }

    // ------------------------------------------------------------------------------------------
    // Entries per page
    // ------------------------------------------------------------------------------------------

    function test_mapsCanSetEntriesPerPage() public pure {
        PagedMap m = PagePack.map("x", 1).withEntriesPerPage(50);

        assertEq(m.entriesPerPage(), 50);
        assertEq(m.dataSlotsPerPage(), 78);
        assertEq(m.width(), 1);
        assertEq((uint256(PagedMap.unwrap(m)) >> 8) & 0xff, 50);

        // The default is as many entries of the map's size as fit, so naming it changes nothing.
        assertEq(
            PagedMap.unwrap(PagePack.map("x", 1).withEntriesPerPage(64)),
            PagedMap.unwrap(PagePack.map("x", 1))
        );
        assertEq(
            PagedMap.unwrap(PagePack.mapWithHomeHints("x", 3).withEntriesPerPage(32)),
            PagedMap.unwrap(PagePack.mapWithHomeHints("x", 3))
        );

        PagedMap kinds = PagePack.mapOfKinds("x").withKind(0, 1).withKind(1, 2).build();
        assertEq(PagedMap.unwrap(kinds.withEntriesPerPage(50)), PagedMap.unwrap(kinds));

        // Setting it twice keeps the last count.
        assertEq(
            PagedMap.unwrap(kinds.withEntriesPerPage(40).withEntriesPerPage(50)),
            PagedMap.unwrap(kinds)
        );
    }

    /// By default a map of several kinds fits as many of each as it can, in equal numbers.
    function test_kindsSetTheDefaultEntriesPerPage() public pure {
        PagedMap m = PagePack.mapOfKinds("x").withKind(0, 1).build();
        assertEq(m.entriesPerPage(), 64);

        // One- and two-slot entries, 25 of each: 50 tags and 75 of 78 data slots.
        m = PagePack.mapOfKinds("x").withKind(0, 1).withKind(1, 2).build();
        assertEq(m.entriesPerPage(), 50);

        // Four one-slot kinds fit as a map of one does.
        m = PagePack.mapOfKinds("x")
            .withKind(0, 1)
            .withKind(1, 1)
            .withKind(2, 1)
            .withKind(3, 1)
            .build();
        assertEq(m.entriesPerPage(), 64);

        // Too wide for one of each: as many of the widest as fit.
        m = PagePack.mapOfKinds("x").withKind(0, 1).withKind(1, 127).build();
        assertEq(m.entriesPerPage(), 1);

        m = PagePack.mapOfKinds("x").withKind(0, 60).withKind(1, 60).withKind(2, 60).build();
        assertEq(m.entriesPerPage(), 2);
    }

    function test_invalidEntriesPerPageReverts() public {
        MapFactory factory = new MapFactory();

        vm.expectRevert(abi.encodeWithSelector(PagePack.InvalidEntriesPerPage.selector, 0));
        factory.map(1, 0);

        // Every entry needs a data slot as well as a tag.
        vm.expectRevert(abi.encodeWithSelector(PagePack.InvalidEntriesPerPage.selector, 65));
        factory.map(1, 65);

        // An entry of the map's own size must fit the data region.
        vm.expectRevert(abi.encodeWithSelector(PagePack.InvalidEntriesPerPage.selector, 29));
        factory.map(100, 29);

        factory.map(100, 28);
        factory.map(1, 64);
    }

    /// Two-slot accounts and one-slot approvals, one each: 64 tags leave room for 21 pairs on a
    /// page, and the default for the two kinds, 50 tags, for 25.
    function test_fewerTagsFitMoreMixedEntries() public {
        PagePack.Placement[] memory placements = new PagePack.Placement[](50);

        for (uint256 i; i < 50; ++i) {
            placements[i] = PagePack.Placement(_key(1 - i % 2, i), i);
        }

        uint256[] memory sizes = new uint256[](2);
        (sizes[0], sizes[1]) = (1, 2);

        store = new KindedEntryStore(sizes, 64, false);
        vm.expectRevert(abi.encodeWithSelector(PagePack.PageFull.selector, 0));
        store.rebalance(placements);

        store = new KindedEntryStore(sizes, 0, false);
        assertEq(store.entriesPerPage(), 50);

        for (uint256 i; i < 50; ++i) {
            _fillAll(_key(1 - i % 2, i), 10 * i);
        }

        store.rebalance(placements);

        uint256 page = (_directory() + 128) >> 7;

        for (uint256 i; i < 50; ++i) {
            assertEq(store.slotOf(_key(1 - i % 2, i)) >> 7, page, "another page");
            _assertAll(_key(1 - i % 2, i), 10 * i);
        }
    }

    // ------------------------------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------------------------------

    /// Packs, moves and evicts a random set of entries and checks that every value survives and
    /// every entry is found where the directory says it is.
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
        store.rebalance(first);

        // Round two: evict some packed entries, move some, and pack some new ones.
        PagePack.Placement[] memory second = new PagePack.Placement[](n);
        uint256 secondCount;

        for (uint256 i; i < n; ++i) {
            uint256 roll = _random(seed, i + 2000) % 4;

            if (indexOf[i] != 0 && roll == 0) {
                second[secondCount++] = PagePack.Placement(_key(i), PagePack.HOME);
                indexOf[i] = 0;
            } else if (roll == 1) {
                uint256 index = _freeIndex(taken, _random(seed, i + 3000));
                second[secondCount++] = PagePack.Placement(_key(i), index);
                indexOf[i] = index + 1;
            }
        }

        _truncate(second, secondCount);
        store.rebalance(second);

        uint256 packed;

        for (uint256 i; i < n; ++i) {
            assertEq(store.hintOf(_key(i)), indexOf[i]);
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
        return uint256(keccak256(abi.encode(store.MAP(), key)));
    }

    function _home(bytes32 key) internal view returns (uint256) {
        return _identity(key) & ~uint256(127);
    }

    function _directory() internal view returns (uint256) {
        return uint256(keccak256(abi.encode(store.MAP()))) & ~uint256(127);
    }

    /// The slot holding packed `index`'s tag: packed pages follow the directory, and each starts
    /// with its tags.
    function _tagSlot(uint256 index) internal view returns (uint256) {
        uint256 perPage = store.entriesPerPage();
        return _directory() + 128 * (index / perPage + 1) + index % perPage;
    }

    function _load(uint256 location) internal view returns (uint256) {
        return uint256(vm.load(address(store), bytes32(location)));
    }

    function _assertNotRead(bytes32[] memory reads, uint256 location) internal pure {
        for (uint256 i; i < reads.length; ++i) {
            assertTrue(uint256(reads[i]) != location, "read the directory");
        }
    }

    function _hint(bytes32 key, uint256 hint) internal pure returns (PagePack.Hint[] memory hints) {
        hints = new PagePack.Hint[](1);
        hints[0] = PagePack.Hint(key, hint);
    }

    function _flag(bytes32 key) internal view returns (uint256) {
        return uint256(vm.load(address(store), bytes32(_home(key) + 127)));
    }

    /// A key of `kind`: the kind in the top byte over 31 bytes of a hash.
    function _key(uint256 kind, uint256 i) internal pure returns (bytes32) {
        return bytes32((kind << 248) | (uint256(keccak256(abi.encode("key", i))) >> 8));
    }

    /// A store whose kinds 0, 1, ... have these sizes, with the default entries per page.
    function _kinded(uint256 a, uint256 b) internal returns (KindedEntryStore) {
        uint256[] memory sizes = new uint256[](2);
        (sizes[0], sizes[1]) = (a, b);

        return new KindedEntryStore(sizes, 0, false);
    }

    function _kinded(uint256 a, uint256 b, uint256 c) internal returns (KindedEntryStore) {
        uint256[] memory sizes = new uint256[](3);
        (sizes[0], sizes[1], sizes[2]) = (a, b, c);

        return new KindedEntryStore(sizes, 0, false);
    }

    /// Writes value, value + 1, ... into each of the entry's slots.
    function _fillAll(bytes32 key, uint256 value) internal {
        uint256 slots = store.sizeOf(key);

        for (uint256 i; i < slots; ++i) {
            store.set(key, i, value + i);
        }
    }

    function _assertAll(bytes32 key, uint256 value) internal view {
        uint256 slots = store.sizeOf(key);

        for (uint256 i; i < slots; ++i) {
            assertEq(store.get(key, i), value + i);
        }
    }

    function _fingerprint(bytes32 key) internal view returns (uint256) {
        return _identity(key) >> 234;
    }

    /// Writes value, value + 1, value + 2 into the entry's three slots.
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
        store.rebalance(_placement(key, index));
    }

    function _placement(bytes32 key, uint256 index)
        internal
        pure
        returns (PagePack.Placement[] memory placements)
    {
        placements = new PagePack.Placement[](1);
        placements[0] = PagePack.Placement(key, index);
    }

    function _eviction(bytes32 key) internal pure returns (PagePack.Placement[] memory placements) {
        placements = new PagePack.Placement[](1);
        placements[0] = PagePack.Placement(key, PagePack.HOME);
    }

    function _join(PagePack.Placement[] memory a, PagePack.Placement[] memory b)
        internal
        pure
        returns (PagePack.Placement[] memory joined)
    {
        joined = new PagePack.Placement[](a.length + b.length);

        for (uint256 i; i < a.length; ++i) {
            joined[i] = a[i];
        }

        for (uint256 i; i < b.length; ++i) {
            joined[a.length + i] = b[i];
        }
    }

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

    /// Returns `count` keys with distinct fingerprints in the current store's map.
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
