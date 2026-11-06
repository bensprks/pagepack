// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LibDirectory} from "./LibDirectory.sol";

/// Fixed-size entries looked up by key, such as "balances" or "allowances".
///
/// Entries can only share a page with entries in the same map, so put entities that are used
/// together into one map. Entries of different sizes can share a map: look each size up through
/// its own view, `m.sized(slots)`.
///
/// The low byte holds the map's own entry size in slots (7 bits) and, in its top bit, whether
/// the map keeps home flags for HOME hints. The next byte holds the size of the entries this
/// handle looks up: the map's own size, or a view's. The third holds the map's entries per page.
type PagedMap is bytes32;

/// The first data slot of an entry, wherever the entry currently lives.
///
/// Use it a slot at a time with {read} and {write}, or lay a struct over it and let Solidity
/// handle the field offsets and packing:
///
///     Account storage account;
///     assembly ("memory-safe") {
///         account.slot := e
///     }
///
/// An Entry is a raw storage pointer, and so is a struct laid over one. Nothing checks how they
/// are used:
/// - Offsets aren't bounds-checked. The slot after an entry may already hold another entry's
///   data, so a struct must be at most the size it was looked up with: the map's width, or the
///   size passed to {sized}. Take that size from the struct, or check it with {requireFits}.
///   Either way, measure the struct with a helper: in a `T[2] storage` array placed at slot 0,
///   element 1's slot is T's size in slots. Declare the helper `view`, not `pure`: the compiler
///   treats indexing a storage array as a possible read, though nothing is read.
/// - They go stale when the entry moves. Look the entry up again, and lay the struct over it
///   again, after anything in the same transaction that could rebalance, including an external
///   call that might re-enter.
/// - Entries hold fixed-size values only. Mappings, dynamic arrays, strings and bytes keep their
///   contents at slots derived from the entry's location, so a move would leave them behind.
///   Keep such data in its own storage, keyed by the entry's key.
type Entry is uint256;

using PagePack for PagedMap global;
using PagePack for Entry global;

/// @title PagePack
/// @notice Packs storage entries that are used together onto shared MIP-8 pages.
///
/// MIP-8 prices storage by 128-slot page: the first touch of a page in a transaction costs
/// 8,100 gas and every later slot on it costs 100. A mapping puts each entry on its own page, so
/// touching N entries costs N page loads. PagePack lets an admin move hot entries onto shared
/// pages, so a transaction touching N packed entries on k pages pays for k loads instead.
///
/// An entry lives in one of two places:
///
///   home     keccak256(map, key), rounded down to a page boundary. Every entry starts here,
///            and it costs the same as a mapping entry. In a map made with
///            {mapWithHomeHints}, the last slot of the home page holds a flag while the entry
///            is packed.
///   packed   a numbered index in the map's packed region, placed there by {rebalance}. Each
///            packed page starts with a tag for each of its indices, and the entries' data
///            fills the rest of the page. A tag holds the entry's identity, so a lookup can
///            confirm it found the right entry, and where on the page its data is.
///
/// An entry's identity hashes its size in with the map and the key, so the same key looked up
/// at two sizes names two different entries.
///
/// Each map keeps one directory page mapping a short fingerprint of every packed entry to its
/// index. A lookup without a hint searches the directory, paying for that page once per
/// transaction. A lookup with a correct hint skips the directory entirely: a packed index is
/// checked against its tag, and a HOME hint (home-hint maps only) against the flag.
///
/// Storage layout of a map, all page-aligned:
///
///   D = keccak256(map) rounded down to a page boundary
///   D + 0              number of packed entries
///   D + 1 .. D + 127   directory entries, 8 per slot, sorted by fingerprint (see LibDirectory)
///   D + 128 ...        packed pages of T = {entriesPerPage} indices each:
///                        slots 0 .. T - 1     a tag per index, zero while the index is empty
///                        slots T .. 127       entries' data, wherever {rebalance} put it
///
/// A tag is the entry's identity with its low 14 bits replaced by where its data starts on the
/// page (bits 7 to 13) and its size in slots (bits 0 to 6). Lookups only ever read tags from the
/// tag region, so nothing written into an entry's data can pose as a tag.
library PagePack {
    /// Puts the entry for `key` at packed `index`, or sends it home if `index` is HOME. `slots`
    /// is the entry's size, 0 for the map's own.
    struct Placement {
        bytes32 key;
        uint256 slots;
        uint256 index;
    }

    struct Hint {
        bytes32 key;
        uint256 hint;
    }

    /// An entry named in a rebalance: where it is and where it goes, as packed indices and as
    /// the first slot of its data. Internal to {rebalance}.
    struct Move {
        bytes32 key;
        uint256 id;
        uint256 slots;
        uint256 from;
        uint256 to;
        uint256 position;
        uint256 source;
        uint256 target;
    }

    error InvalidWidth(uint256 width);
    error InvalidEntriesPerPage(uint256 perPage);
    error StructTooWide(uint256 slots, uint256 width);
    error EntryTooWide(uint256 slots);
    error IndexOutOfRange(uint256 index);
    error IndexTaken(uint256 index);
    error PageFull(uint256 page);
    error NotPacked(bytes32 key);
    error DuplicateKey(bytes32 key);
    error FingerprintCollision(bytes32 key);
    error DirectoryFull();

    uint256 internal constant PAGE_SIZE = 128;
    uint256 internal constant MAX_WIDTH = 127;

    /// Entries a map's directory can list.
    uint256 internal constant MAX_PACKED = LibDirectory.CAPACITY;

    /// Packed indices are stored in 10 bits.
    uint256 internal constant MAX_INDEX = LibDirectory.INDEX_LIMIT;

    /// The hint for an entry that isn't packed, in a map made with {mapWithHomeHints}. Other
    /// maps ignore it. Packed entries' hints are index + 1, so they never reach it. As a
    /// placement's index, it sends the entry home.
    uint256 internal constant HOME = MAX_INDEX + 1;

    // The low byte of a map: its own size, and a bit for maps that keep home flags. The byte
    // above holds the size of the entries a handle looks up, and the one above that the map's
    // entries per page.
    uint256 private constant MAP_SLOTS_MASK = 0x7f;
    uint256 private constant HOME_HINTS = 0x80;
    uint256 private constant SLOTS_SHIFT = 8;
    uint256 private constant SLOTS_BYTE = 0xff00;
    uint256 private constant PER_PAGE_SHIFT = 16;

    // Every entry on a page needs a data slot as well as a tag.
    uint256 private constant MAX_PER_PAGE = PAGE_SIZE / 2;

    // A hint's low 11 bits are index + 1 or HOME. A hint from a view of another size holds that
    // size above them. Plain literals, so that inline assembly can use them.
    uint256 private constant HINT_MASK = 0x7ff;
    uint256 private constant HINT_SLOTS_SHIFT = 11;
    uint256 private constant INDEX_LIMIT = 1024;
    uint256 private constant HOME_HINT = 1025;

    // A tag's low 14 bits: where the entry's data starts on its page, and its size. The bits
    // above are the entry's identity.
    uint256 private constant TAG_OFFSET_SHIFT = 7;
    uint256 private constant TAG_FIELD_MASK = 0x7f;
    uint256 private constant TAG_IDENTITY_SHIFT = 14;

    // A move's position when the entry is at home.
    uint256 private constant AT_HOME = type(uint256).max;

    // What a page search returns when no run of free slots is long enough.
    uint256 private constant NO_FIT = 0xffff;

    // ------------------------------------------------------------------------------------------
    // Maps
    // ------------------------------------------------------------------------------------------

    /// @notice Creates a map of entries that are `slots` slots wide.
    /// @dev Intended for an immutable: `PagedMap immutable BALANCES = PagePack.map("x", 1);`
    ///      A map holding entries of several sizes takes the smallest; each larger size is looked
    ///      up through {sized}.
    function map(string memory name, uint256 slots) internal pure returns (PagedMap) {
        return _map(name, slots, _fullPage(slots), 0);
    }

    /// @notice Like {map}, with `perPage` packed indices on each page instead of as many
    ///         entries of `slots` slots as fit. For a map of several sizes: each page holds
    ///         `perPage` tags, and its entries' sizes can add up to `128 - perPage` slots.
    /// @dev Pick it for the mix the planner packs. Two-slot accounts with one-slot approvals,
    ///      one each, fit 50 to a page with 50 tags (25 of each, 75 data slots), where
    ///      {map}(name, 1) keeps 64 tags and fits 42. Must be 1 to 64 and leave room for an
    ///      entry of `slots`. Part of the map, like its width: a map made with another value
    ///      never shares storage with this one.
    function map(string memory name, uint256 slots, uint256 perPage)
        internal
        pure
        returns (PagedMap)
    {
        return _map(name, slots, perPage, 0);
    }

    /// @notice Like {map}, but packed entries leave a flag on their home page, so a HOME hint
    ///         can confirm an entry isn't packed without loading the directory.
    /// @dev The flag is one live storage slot on every packed entry's home page, so packing no
    ///      longer empties those pages. Use this when transactions often touch entries that
    ///      aren't packed and nothing else loads the directory. The choice is part of the map,
    ///      like its width: the two kinds of map never share storage.
    function mapWithHomeHints(string memory name, uint256 slots) internal pure returns (PagedMap) {
        return _map(name, slots, _fullPage(slots), HOME_HINTS);
    }

    /// @notice Like {mapWithHomeHints}, with `perPage` packed indices on each page. See
    ///         {map}(name, slots, perPage).
    function mapWithHomeHints(string memory name, uint256 slots, uint256 perPage)
        internal
        pure
        returns (PagedMap)
    {
        return _map(name, slots, perPage, HOME_HINTS);
    }

    function _map(string memory name, uint256 slots, uint256 perPage, uint256 mode)
        private
        pure
        returns (PagedMap)
    {
        if (slots == 0 || slots > MAX_WIDTH) revert InvalidWidth(slots);
        if (perPage == 0 || perPage > MAX_PER_PAGE || slots > PAGE_SIZE - perPage) {
            revert InvalidEntriesPerPage(perPage);
        }

        uint256 base = uint256(keccak256(bytes(name))) & ~uint256(0xffffff);
        return PagedMap.wrap(
            bytes32(base | (perPage << PER_PAGE_SHIFT) | (slots << SLOTS_SHIFT) | slots | mode)
        );
    }

    /// As many entries of `slots` slots as fit on a page, each with its tag.
    function _fullPage(uint256 slots) private pure returns (uint256) {
        return slots == 0 ? 0 : PAGE_SIZE / (slots + 1);
    }

    /// @notice A view of the map for entries of `slots` slots, for a map holding entries of
    ///         several sizes. Look up, hint and fingerprint them through it as through the map.
    /// @dev Cheap enough to call on every lookup: it only rewrites a byte of the handle. Reverts
    ///      unless an entry of that size fits a packed page's data region.
    function sized(PagedMap m, uint256 slots) internal pure returns (PagedMap) {
        unchecked {
            if (slots - 1 >= m.dataSlotsPerPage()) revert EntryTooWide(slots);
        }

        return _withSlots(m, slots);
    }

    /// @notice Number of data slots in each entry this handle looks up: the map's own size, or
    ///         the size given to {sized}.
    function width(PagedMap m) internal pure returns (uint256) {
        return (uint256(PagedMap.unwrap(m)) & SLOTS_BYTE) >> SLOTS_SHIFT;
    }

    /// @notice Reverts unless a struct of `slots` slots fits within the entries this handle looks
    ///         up.
    /// @dev For a map whose width is set by hand, such as one pinned to the size of its largest
    ///      kind of entry: check each struct's size when creating the map. A narrower struct
    ///      leaves the rest of its entry unused; a wider one would write into the next packed
    ///      entry. Kinds looked up through {sized} with their own size always fit.
    function requireFits(PagedMap m, uint256 slots) internal pure {
        if (slots > m.width()) revert StructTooWide(slots, m.width());
    }

    /// @notice Whether the map keeps home flags, so HOME hints work.
    function homeHints(PagedMap m) internal pure returns (bool) {
        return uint256(PagedMap.unwrap(m)) & HOME_HINTS != 0;
    }

    /// @notice Number of packed indices on one page: by default, as many entries of the map's
    ///         own size as fit on a page, each with its tag.
    function entriesPerPage(PagedMap m) internal pure returns (uint256 perPage) {
        assembly ("memory-safe") {
            perPage := and(shr(PER_PAGE_SHIFT, m), 0xff)
        }
    }

    /// @notice Number of slots on each packed page for entries' data, after the tags. Entries
    ///         on a page can be of any sizes that add up to at most this.
    function dataSlotsPerPage(PagedMap m) internal pure returns (uint256) {
        return PAGE_SIZE - m.entriesPerPage();
    }

    /// @notice Number of entries currently packed.
    function packedCount(PagedMap m) internal view returns (uint256) {
        return LibDirectory.length(_directory(m));
    }

    /// @notice The 22-bit fingerprint the directory keeps for `key`.
    /// @dev Two entries with the same fingerprint can't both be packed in one map. Planners
    ///      should check new placements against the packed set and leave one of any clashing pair
    ///      at home; with 1,016 random keys, about 1 layout in 9 contains such a pair.
    function fingerprintOf(PagedMap m, bytes32 key) internal pure returns (uint256) {
        return LibDirectory.fingerprintOf(_identity(m, key));
    }

    // ------------------------------------------------------------------------------------------
    // Lookup
    // ------------------------------------------------------------------------------------------

    // Lookups run on every entry access, so their arithmetic is unchecked. Sizes are at most
    // 127, indices below 1024 and slots come from hashes, so none of it can overflow in practice.

    /// @notice Locates the entry for `key`, using a hint from {useHints} if there is one.
    /// @dev Without a hint, every call searches the directory, which costs about 1,000 to 1,400
    ///      gas once its page is loaded. Look an entry up once per call and pass the Entry along
    ///      while nothing can rebalance.
    function find(PagedMap m, bytes32 key) internal view returns (Entry e) {
        uint256 id;
        uint256 dir;
        uint256 perPage;
        bool hinted;

        // The hot path for every lookup, so it is assembly. It makes the same checks as
        // find(key, hint), and most lookups have no hint and skip them with one comparison.
        assembly ("memory-safe") {
            mstore(0x00, m)
            mstore(0x20, key)
            id := keccak256(0x00, 0x40)

            mstore(0x00, and(m, not(SLOTS_BYTE)))
            dir := and(keccak256(0x00, 0x20), not(127))
            perPage := and(shr(PER_PAGE_SHIFT, m), 0xff)

            let hint := tload(id)

            if hint {
                let index := sub(hint, 1)

                switch lt(index, INDEX_LIMIT)
                case 1 {
                    let page := add(dir, shl(7, add(div(index, perPage), 1)))
                    let tag := sload(add(page, mod(index, perPage)))

                    if eq(shr(TAG_IDENTITY_SHIFT, tag), shr(TAG_IDENTITY_SHIFT, id)) {
                        e := add(page, and(shr(TAG_OFFSET_SHIFT, tag), TAG_FIELD_MASK))
                        hinted := 1
                    }
                }
                default {
                    // HOME, in a map that keeps home flags: the entry is home if its flag is
                    // clear.
                    if and(eq(index, INDEX_LIMIT), shr(7, and(m, HOME_HINTS))) {
                        let home := and(id, not(127))

                        if iszero(sload(add(home, 127))) {
                            e := home
                            hinted := 1
                        }
                    }
                }
            }
        }

        if (hinted) return e;

        (bool found, uint256 index,) = LibDirectory.search(dir, id);

        if (found) {
            // Fingerprints are short, so a match is only a candidate until the tag agrees.
            (bool tagged, uint256 data) = _packed(dir, perPage, id, index);
            if (tagged) return Entry.wrap(data);
        }

        return Entry.wrap(_home(id));
    }

    /// @notice Locates the entry for `key`, checking `hint` before the directory.
    /// @dev A hint is the value returned by {hintOf}; 0 means no hint. A wrong or stale hint
    ///      falls back to the directory, so it can cost gas but never returns the wrong entry.
    function find(PagedMap m, bytes32 key, uint256 hint) internal view returns (Entry e) {
        bool hinted;

        assembly ("memory-safe") {
            // A size above the low bits only tells useHints which entry the hint is for.
            // hint - 1 wraps to a huge number when hint is 0, so one comparison rejects both
            // "no hint" and out-of-range hints.
            let index := sub(and(hint, HINT_MASK), 1)

            mstore(0x00, m)
            mstore(0x20, key)

            switch lt(index, INDEX_LIMIT)
            case 1 {
                let id := keccak256(0x00, 0x40)

                mstore(0x00, and(m, not(SLOTS_BYTE)))
                let dir := and(keccak256(0x00, 0x20), not(127))
                let perPage := and(shr(PER_PAGE_SHIFT, m), 0xff)
                let page := add(dir, shl(7, add(div(index, perPage), 1)))
                let tag := sload(add(page, mod(index, perPage)))

                if eq(shr(TAG_IDENTITY_SHIFT, tag), shr(TAG_IDENTITY_SHIFT, id)) {
                    e := add(page, and(shr(TAG_OFFSET_SHIFT, tag), TAG_FIELD_MASK))
                    hinted := 1
                }
            }
            default {
                // HOME, in a map that keeps home flags. The flag shares the home page, so this
                // costs what a mapping entry does.
                if and(eq(index, INDEX_LIMIT), shr(7, and(m, HOME_HINTS))) {
                    let home := and(keccak256(0x00, 0x40), not(127))

                    if iszero(sload(add(home, 127))) {
                        e := home
                        hinted := 1
                    }
                }
            }
        }

        if (hinted) return e;

        return find(m, key);
    }

    /// @notice Remembers hints for the rest of the transaction, so {find} without a hint uses
    ///         them. Load a batch's hints once at the entry point instead of passing one to every
    ///         lookup.
    /// @dev Hints live in transient storage under each entry's identity and vanish when the
    ///      transaction ends. Checking for one costs {find} about 100 gas. Wrong or stale hints
    ///      are as safe as they are with {find}(key, hint).
    ///
    ///      Each hint names its entry's size the way {hintOf} returns it, so one list can hold
    ///      hints for entries of every size, whichever handle loads it.
    function useHints(PagedMap m, Hint[] calldata hints) internal {
        assembly ("memory-safe") {
            let own := and(m, MAP_SLOTS_MASK)
            let handle := and(m, not(SLOTS_BYTE))
            let end := add(hints.offset, shl(6, hints.length))

            for { let h := hints.offset } lt(h, end) { h := add(h, 0x40) } {
                let hint := calldataload(add(h, 0x20))
                let slots := shr(HINT_SLOTS_SHIFT, hint)
                if iszero(slots) { slots := own }

                mstore(0x00, or(handle, shl(SLOTS_SHIFT, and(slots, 0xff))))
                mstore(0x20, calldataload(h))
                tstore(keccak256(0x00, 0x40), and(hint, HINT_MASK))
            }
        }
    }

    /// @notice Remembers one hint for the rest of the transaction, for an entry of this
    ///         handle's size. See {useHints}.
    function useHint(PagedMap m, bytes32 key, uint256 hint) internal {
        uint256 id = _identity(m, key);
        hint &= HINT_MASK;

        assembly ("memory-safe") {
            tstore(id, hint)
        }
    }

    /// @notice The hint for `key`: its packed index plus one. An entry that isn't packed has
    ///         HOME in a home-hint map, and 0 (no hint) elsewhere. On a view of another size
    ///         than the map's own, a hint also holds that size, shifted left by 11 bits, for
    ///         {useHints}.
    /// @dev Meant to be called offchain (via an eth_call wrapper) to build hints for a batch.
    function hintOf(PagedMap m, bytes32 key) internal view returns (uint256 hint) {
        (uint256 index,,) = _locate(_directory(m), m.entriesPerPage(), _identity(m, key));

        if (index != AT_HOME) hint = index + 1;
        else if (m.homeHints()) hint = HOME;
        else return 0;

        uint256 slots = m.width();
        if (slots != uint256(PagedMap.unwrap(m)) & MAP_SLOTS_MASK) {
            hint |= slots << HINT_SLOTS_SHIFT;
        }
    }

    // ------------------------------------------------------------------------------------------
    // Entries
    // ------------------------------------------------------------------------------------------

    /// @notice Reads data slot `offset` of the entry. Unchecked: keep `offset` below the width.
    function read(Entry e, uint256 offset) internal view returns (uint256 value) {
        assembly ("memory-safe") {
            value := sload(add(e, offset))
        }
    }

    /// @notice Writes data slot `offset` of the entry. Unchecked: keep `offset` below the width.
    function write(Entry e, uint256 offset, uint256 value) internal {
        assembly ("memory-safe") {
            sstore(add(e, offset), value)
        }
    }

    /// @notice The storage slot where the entry's data starts.
    function slot(Entry e) internal pure returns (uint256) {
        return Entry.unwrap(e);
    }

    // ------------------------------------------------------------------------------------------
    // Rebalancing
    // ------------------------------------------------------------------------------------------

    /// @notice Moves the named entries to new positions in one atomic step.
    /// @dev Each placement puts an entry at a packed index, or sends a packed entry home if its
    ///      index is HOME. Entries that aren't named stay where they are. The request describes
    ///      the layout after the call, so its order doesn't matter and swaps and cycles work: a
    ///      placement may target an index whose entry is evicted or placed elsewhere in the same
    ///      call. Placing an entry at the index it already holds does nothing, so a caller can
    ///      resubmit a layout cheaply.
    ///
    ///      A placement names the entry's size, which is part of its identity: a wrong size names
    ///      another entry, usually an empty one at home, and leaves the intended one where it is.
    ///
    ///      The call picks each arriving entry's data slots: the first gap on the page that
    ///      fits, in placement order. An entry moving to another index on the same page keeps
    ///      its data where it is. If no gap fits but the page has enough free slots, the entries
    ///      staying on the page are moved together first; their indices, and so their hints,
    ///      don't change. A page fits a layout if the sizes of its entries add up to at most
    ///      {dataSlotsPerPage}.
    ///
    ///      Reverts if a key is named twice at one size, an eviction names an entry that isn't
    ///      packed, two placements share an index, a placement targets an index held by an
    ///      entry the call doesn't move, an entry is too wide for a page, a page's entries
    ///      don't fit it, two packed entries would share a fingerprint, or the directory would
    ///      overflow.
    ///
    ///      Packing an entry from home costs about 62,000 gas, mostly MIP-8's charge for two new
    ///      slots, so split large layouts across transactions. Each page that receives entries
    ///      also has its tags read once, up to 100 gas per index. The sort of newly packed
    ///      entries returns early if the caller lists them in fingerprint order
    ///      ({fingerprintOf}).
    ///
    ///      There is no access control here: the calling contract decides who may rebalance.
    function rebalance(PagedMap m, Placement[] memory placements) internal {
        if (placements.length == 0) return;

        uint256 dir = _directory(m);
        uint256 perPage = m.entriesPerPage();

        Move[] memory moves = _plan(m, dir, perPage, placements);
        moves = _allocate(dir, perPage, moves);

        _relocate(dir, perPage, moves, m.homeHints());
        _updateIndices(dir, moves);
        _rebuild(dir, moves);
    }

    /// Works out where each named entry is and where it goes, and rejects any request that
    /// doesn't describe a valid layout. Entries already in place need no move and are left out.
    /// Packed destinations get their data slots later, in {_allocate}.
    function _plan(PagedMap m, uint256 dir, uint256 perPage, Placement[] memory placements)
        private
        view
        returns (Move[] memory moves)
    {
        moves = new Move[](placements.length);
        uint256 count;

        // Bitmaps over packed indices: those holding an entry this call names, and those a
        // placement targets. Indices are below 1,024, so four words cover them.
        uint256[4] memory named;
        uint256[4] memory claimed;

        for (uint256 i; i < placements.length; ++i) {
            Placement memory p = placements[i];
            (uint256 id, uint256 slots, bool inPlace) = _check(m, dir, perPage, p, named, claimed);

            if (!inPlace) moves[count++] = _moveFor(dir, perPage, p, id, slots, named);
        }

        // A target must be empty or hold an entry this call names. Since no two placements share
        // a target, a named occupant is always leaving.
        for (uint256 i; i < count; ++i) {
            uint256 index = moves[i].to;
            if (index == AT_HOME) continue;

            if (!_isMarked(named, index) && _load(_tagSlot(dir, perPage, index)) != 0) {
                revert IndexTaken(index);
            }
        }

        assembly ("memory-safe") {
            mstore(moves, count)
        }
    }

    /// Checks a placement against the request so far, and returns its entry's identity and
    /// size, and whether the entry is already where it is placed.
    function _check(
        PagedMap m,
        uint256 dir,
        uint256 perPage,
        Placement memory p,
        uint256[4] memory named,
        uint256[4] memory claimed
    ) private view returns (uint256 id, uint256 slots, bool inPlace) {
        slots = p.slots;

        // Runs for every placement, including each one of a resubmitted layout, so it is
        // assembly: the entry's identity at its size, and whether its target already holds it.
        assembly ("memory-safe") {
            if iszero(slots) { slots := and(m, MAP_SLOTS_MASK) }

            mstore(0x00, or(and(m, not(SLOTS_BYTE)), shl(SLOTS_SHIFT, and(slots, 0xff))))
            mstore(0x20, mload(p))
            id := keccak256(0x00, 0x40)

            let index := mload(add(p, 0x40))

            if lt(index, INDEX_LIMIT) {
                let page := add(dir, shl(7, add(div(index, perPage), 1)))
                let tag := sload(add(page, mod(index, perPage)))

                inPlace := eq(shr(TAG_IDENTITY_SHIFT, tag), shr(TAG_IDENTITY_SHIFT, id))
            }
        }

        if (slots > PAGE_SIZE - perPage) revert EntryTooWide(slots);
        if (p.index == HOME) return (id, slots, false);

        if (p.index >= MAX_INDEX) revert IndexOutOfRange(p.index);
        if (_mark(claimed, p.index)) revert IndexTaken(p.index);

        // A resubmitted entry is usually already in place, which also skips the search.
        if (inPlace && _mark(named, p.index)) revert DuplicateKey(p.key);
    }

    /// The move a checked placement makes.
    function _moveFor(
        uint256 dir,
        uint256 perPage,
        Placement memory p,
        uint256 id,
        uint256 slots,
        uint256[4] memory named
    ) private view returns (Move memory move) {
        move = _moveFrom(dir, perPage, p.key, id, slots);

        if (p.index == HOME) {
            if (move.from == AT_HOME) revert NotPacked(p.key);
        } else {
            move.to = p.index;
            if (move.from == AT_HOME) return move;
        }

        if (_mark(named, move.from)) revert DuplicateKey(p.key);
    }

    /// A move of the entry with `id` from wherever it is now, to its home until the caller says
    /// otherwise.
    function _moveFrom(uint256 dir, uint256 perPage, bytes32 key, uint256 id, uint256 slots)
        private
        view
        returns (Move memory)
    {
        (uint256 from, uint256 position, uint256 source) = _locate(dir, perPage, id);

        return Move(key, id, slots, from, AT_HOME, position, source, id & ~(PAGE_SIZE - 1));
    }

    // ------------------------------------------------------------------------------------------
    // Allocation
    // ------------------------------------------------------------------------------------------

    /// Picks the data slots of every move to a packed index. An entry moving within its page
    /// keeps its data; entries arriving on a page take its gaps, first fit in placement order.
    /// Returns the moves, plus a move for each staying entry that a full page had to shift.
    function _allocate(uint256 dir, uint256 perPage, Move[] memory moves)
        private
        view
        returns (Move[] memory)
    {
        // Packed indices whose entry leaves its page, so its data slots come free.
        uint256[4] memory leaving;

        for (uint256 i; i < moves.length; ++i) {
            Move memory move = moves[i];
            if (move.from == AT_HOME) continue;

            if (move.to != AT_HOME && move.to / perPage == move.from / perPage) {
                move.target = move.source;
            } else {
                _mark(leaving, move.from);
            }
        }

        // Each page's slots in use, read from its tags when an entry first arrives on it. The
        // tag region is always in use, so a loaded page is never 0.
        uint256[] memory used = new uint256[]((MAX_INDEX + perPage - 1) / perPage);

        for (uint256 i; i < moves.length; ++i) {
            Move memory move = moves[i];
            if (move.to == AT_HOME) continue;

            // Only entries arriving from home or another page need slots.
            uint256 page = move.to / perPage;
            if (move.from != AT_HOME && move.from / perPage == page) continue;

            uint256 start = dir + ((page + 1) << 7);
            uint256 pageUsed = used[page];

            if (pageUsed == 0) pageUsed = _occupancy(start, perPage, page, leaving);

            uint256 offset = _firstFit(pageUsed, move.slots);

            if (offset == NO_FIT) {
                if (_countFree(pageUsed) < move.slots) revert PageFull(page);

                (moves, offset) = _compact(start, perPage, moves, i, page, leaving);
                pageUsed = _range(0, offset);
            }

            move.target = start + offset;
            used[page] = pageUsed | _range(offset, move.slots);
        }

        return moves;
    }

    /// Whether a move brings an entry onto its target page from home or another page.
    function _arrives(Move memory move, uint256 perPage) private pure returns (bool) {
        return
            move.to != AT_HOME && (move.from == AT_HOME || move.from / perPage != move.to / perPage);
    }

    /// A bitmap of a page's slots in use once this call's departures leave: the tag region, and
    /// the data of every entry that stays on the page.
    ///
    /// Reads every tag on the page, so it is assembly: in Solidity, the checks and calls cost
    /// more than the reads.
    function _occupancy(uint256 start, uint256 perPage, uint256 page, uint256[4] memory leaving)
        private
        view
        returns (uint256 used)
    {
        uint256 first = page * perPage;
        uint256 tags = _min(perPage, MAX_INDEX - first);

        assembly ("memory-safe") {
            used := sub(shl(perPage, 1), 1)

            for { let t := 0 } lt(t, tags) { t := add(t, 1) } {
                let tag := sload(add(start, t))

                if tag {
                    let index := add(first, t)
                    let bits := mload(add(leaving, shl(5, shr(8, index))))

                    if iszero(and(shr(and(index, 255), bits), 1)) {
                        let slots := and(tag, TAG_FIELD_MASK)
                        let offset := and(shr(TAG_OFFSET_SHIFT, tag), TAG_FIELD_MASK)

                        used := or(used, shl(offset, sub(shl(slots, 1), 1)))
                    }
                }
            }
        }
    }

    /// Slides the data of every entry staying on `page` down against the tag region, in the
    /// order it sits, then lines up the entries that arrived before move `upTo`. Entries that
    /// already sit where they belong don't move. Returns the moves, with a move added for each
    /// unmoved entry that shifts, and the first free slot after them all.
    ///
    /// Only runs when a page has room for an arriving entry but no gap that fits it.
    function _compact(
        uint256 start,
        uint256 perPage,
        Move[] memory moves,
        uint256 upTo,
        uint256 page,
        uint256[4] memory leaving
    ) private view returns (Move[] memory grown, uint256 next) {
        // Each staying entry's index plus one, by where its data starts.
        uint256[] memory byOffset = new uint256[](PAGE_SIZE);
        uint256 first = page * perPage;
        uint256 end = _min(first + perPage, MAX_INDEX);

        for (uint256 index = first; index < end; ++index) {
            uint256 tag = _load(start + index - first);
            if (tag != 0 && !_isMarked(leaving, index)) byOffset[_offsetOf(tag)] = index + 1;
        }

        (grown, next) = _slide(start, perPage, moves, byOffset);

        // Entries that already arrived on this page follow, in placement order.
        for (uint256 i; i < upTo; ++i) {
            Move memory move = moves[i];
            if (!_arrives(move, perPage) || move.to / perPage != page) continue;

            move.target = start + next;
            next += move.slots;
        }
    }

    /// Lays the staying entries listed in `byOffset` out one after another from the end of the
    /// tag region. See {_compact}.
    function _slide(uint256 start, uint256 perPage, Move[] memory moves, uint256[] memory byOffset)
        private
        view
        returns (Move[] memory grown, uint256 next)
    {
        grown = new Move[](moves.length + perPage);
        uint256 count = moves.length;

        for (uint256 i; i < count; ++i) {
            grown[i] = moves[i];
        }

        next = perPage;

        for (uint256 offset = perPage; offset < PAGE_SIZE; ++offset) {
            if (byOffset[offset] == 0) continue;

            uint256 index = byOffset[offset] - 1;
            uint256 tag = _load(start + index % perPage);

            if (offset != next) {
                Move memory mover = _leaving(moves, index);

                if (mover.slots != 0) {
                    mover.target = start + next;
                } else {
                    // An unmoved entry keeps its index and gets a new tag, for which its old
                    // tag's identity bits are all it needs.
                    grown[count++] = Move(
                        bytes32(0),
                        tag,
                        tag & TAG_FIELD_MASK,
                        index,
                        index,
                        0,
                        start + offset,
                        start + next
                    );
                }
            }

            next += tag & TAG_FIELD_MASK;
        }

        assembly ("memory-safe") {
            mstore(grown, count)
        }
    }

    /// The move leaving packed `index`, or an empty move if none does.
    function _leaving(Move[] memory moves, uint256 index) private pure returns (Move memory) {
        for (uint256 i; i < moves.length; ++i) {
            if (moves[i].from == index) return moves[i];
        }

        return Move(bytes32(0), 0, 0, 0, 0, 0, 0, 0);
    }

    /// The first slot of a run of `slots` free slots in a page's `used` bitmap, or NO_FIT.
    function _firstFit(uint256 used, uint256 slots) private pure returns (uint256 offset) {
        assembly ("memory-safe") {
            // Bit i of `run` stays set while slots i to i + length - 1 are all free. Doubling
            // the length takes log2(slots) steps, and a last shift covers the rest, since the
            // two windows overlap. Slots past the page are never free, so no run crosses its end.
            let run := and(not(used), sub(shl(PAGE_SIZE, 1), 1))
            let length := 1

            for {} iszero(gt(shl(1, length), slots)) {} {
                run := and(run, shr(length, run))
                length := shl(1, length)
            }

            if gt(slots, length) { run := and(run, shr(sub(slots, length), run)) }

            switch run
            case 0 { offset := NO_FIT }
            default {
                // The lowest set bit, found by halving: run is below 2^128.
                run := and(run, sub(0, run))

                if shr(64, run) {
                    run := shr(64, run)
                    offset := 64
                }
                if shr(32, run) {
                    run := shr(32, run)
                    offset := add(offset, 32)
                }
                if shr(16, run) {
                    run := shr(16, run)
                    offset := add(offset, 16)
                }
                if shr(8, run) {
                    run := shr(8, run)
                    offset := add(offset, 8)
                }
                if shr(4, run) {
                    run := shr(4, run)
                    offset := add(offset, 4)
                }
                if shr(2, run) {
                    run := shr(2, run)
                    offset := add(offset, 2)
                }
                offset := add(offset, shr(1, run))
            }
        }
    }

    function _countFree(uint256 used) private pure returns (uint256 count) {
        uint256 free = ~used & _range(0, PAGE_SIZE);

        while (free != 0) {
            free &= free - 1;
            ++count;
        }
    }

    /// A bitmap of `slots` slots starting at `offset`.
    function _range(uint256 offset, uint256 slots) private pure returns (uint256 bits) {
        assembly ("memory-safe") {
            bits := shl(offset, sub(shl(slots, 1), 1))
        }
    }

    // ------------------------------------------------------------------------------------------
    // Moving data
    // ------------------------------------------------------------------------------------------

    /// Moves each entry's tag and data. Every source is read and cleared before any destination
    /// is written, so an entry can move into slots another is leaving. Clearing first also keeps
    /// a page's occupied-slot count from rising past where it started, so moves within a page
    /// don't pay MIP-8's 17,000 gas state-growth charge. An entry whose data stays put only has
    /// its tag moved. Home flags are set and cleared alongside, when the map keeps them.
    function _relocate(uint256 dir, uint256 perPage, Move[] memory moves, bool flags) private {
        uint256 total;
        for (uint256 i; i < moves.length; ++i) {
            if (moves[i].source != moves[i].target) total += moves[i].slots;
        }

        uint256[] memory data = new uint256[](total);
        uint256 cursor;

        for (uint256 i; i < moves.length; ++i) {
            Move memory m = moves[i];

            if (m.from != AT_HOME) _store(_tagSlot(dir, perPage, m.from), 0);
            if (flags && m.to == AT_HOME) _store(_packedFlag(m.id), 0);
            if (m.source == m.target) continue;

            // Zero words are skipped: there is nothing to clear and nothing to copy.
            for (uint256 w; w < m.slots; ++w) {
                uint256 value = _load(m.source + w);

                if (value != 0) {
                    data[cursor + w] = value;
                    _store(m.source + w, 0);
                }
            }

            cursor += m.slots;
        }

        cursor = 0;

        for (uint256 i; i < moves.length; ++i) {
            Move memory m = moves[i];

            if (m.to != AT_HOME) {
                uint256 offset = m.target - _pageStart(dir, perPage, m.to);
                _store(_tagSlot(dir, perPage, m.to), _tag(m.id, offset, m.slots));
            }

            if (flags && m.from == AT_HOME) _store(_packedFlag(m.id), 1);
            if (m.source == m.target) continue;

            for (uint256 w; w < m.slots; ++w) {
                uint256 value = data[cursor + w];
                if (value != 0) _store(m.target + w, value);
            }

            cursor += m.slots;
        }
    }

    // ------------------------------------------------------------------------------------------
    // Layout
    // ------------------------------------------------------------------------------------------

    /// Identifies an entry in packed storage and derives its home and fingerprint. Hashing the
    /// handle in means the same key in two maps, or at two sizes, never collides, and the result
    /// is never zero in practice, so a zero tag can mark an empty index.
    function _identity(PagedMap m, bytes32 key) private pure returns (uint256 id) {
        assembly ("memory-safe") {
            mstore(0x00, m)
            mstore(0x20, key)
            id := keccak256(0x00, 0x40)
        }
    }

    /// Every size in a map shares one directory, so it ignores the handle's size byte.
    function _directory(PagedMap m) private pure returns (uint256 dir) {
        assembly ("memory-safe") {
            mstore(0x00, and(m, not(SLOTS_BYTE)))
            dir := and(keccak256(0x00, 0x20), not(127))
        }
    }

    /// The handle for entries of `slots` slots in the same map. Sizes above 255 wrap, which
    /// only callers that skip the size check can reach.
    function _withSlots(PagedMap m, uint256 slots) private pure returns (PagedMap) {
        uint256 handle = uint256(PagedMap.unwrap(m)) & ~SLOTS_BYTE;
        return PagedMap.wrap(bytes32(handle | ((slots & 0xff) << SLOTS_SHIFT)));
    }

    /// Page-aligned, so an entry of up to 128 slots never straddles two pages.
    function _home(uint256 id) private pure returns (uint256) {
        return id & ~(PAGE_SIZE - 1);
    }

    /// Set while an entry is packed, in maps that keep home flags. It sits in the last slot of
    /// the home page, which data never reaches because entries are at most 127 slots wide.
    function _packedFlag(uint256 id) private pure returns (uint256) {
        return _home(id) + PAGE_SIZE - 1;
    }

    /// The tag for an entry whose data starts `offset` slots into its page.
    function _tag(uint256 id, uint256 offset, uint256 slots) private pure returns (uint256) {
        return
            (id >> TAG_IDENTITY_SHIFT << TAG_IDENTITY_SHIFT) | (offset << TAG_OFFSET_SHIFT) | slots;
    }

    function _offsetOf(uint256 tag) private pure returns (uint256) {
        return (tag >> TAG_OFFSET_SHIFT) & TAG_FIELD_MASK;
    }

    /// Whether `tag` belongs to the entry with identity `id`.
    function _holds(uint256 tag, uint256 id) private pure returns (bool) {
        return tag >> TAG_IDENTITY_SHIFT == id >> TAG_IDENTITY_SHIFT;
    }

    /// Reads the tag at packed `index` and returns whether it belongs to `id`, and where the
    /// data it points to starts.
    ///
    /// Runs on every packed lookup. perPage is 1..64 and index < 1024, so nothing can overflow
    /// or divide by zero, and skipping Solidity's checks here saves a few hundred gas per call.
    function _packed(uint256 dir, uint256 perPage, uint256 id, uint256 index)
        private
        view
        returns (bool tagged, uint256 data)
    {
        assembly ("memory-safe") {
            let page := add(dir, shl(7, add(div(index, perPage), 1)))
            let tag := sload(add(page, mod(index, perPage)))

            tagged := eq(shr(TAG_IDENTITY_SHIFT, tag), shr(TAG_IDENTITY_SHIFT, id))
            data := add(page, and(shr(TAG_OFFSET_SHIFT, tag), TAG_FIELD_MASK))
        }
    }

    /// The first slot of the packed page holding `index`. Packed pages follow the directory.
    function _pageStart(uint256 dir, uint256 perPage, uint256 index)
        private
        pure
        returns (uint256 start)
    {
        assembly ("memory-safe") {
            start := add(dir, shl(7, add(div(index, perPage), 1)))
        }
    }

    /// The slot holding the tag for packed `index`.
    function _tagSlot(uint256 dir, uint256 perPage, uint256 index)
        private
        pure
        returns (uint256 location)
    {
        assembly ("memory-safe") {
            location := add(add(dir, shl(7, add(div(index, perPage), 1))), mod(index, perPage))
        }
    }

    // ------------------------------------------------------------------------------------------
    // Directory
    // ------------------------------------------------------------------------------------------

    /// An entry's packed index, directory position and first data slot. An entry that isn't
    /// packed is AT_HOME, at its home.
    function _locate(uint256 dir, uint256 perPage, uint256 id)
        private
        view
        returns (uint256 index, uint256 position, uint256 data)
    {
        bool found;
        (found, index, position) = LibDirectory.search(dir, id);

        if (found) {
            bool tagged;
            (tagged, data) = _packed(dir, perPage, id, index);
            if (tagged) return (index, position, data);
        }

        return (AT_HOME, 0, _home(id));
    }

    /// Rewrites the index bits of entries that moved between packed indices. Their fingerprints
    /// don't change, so the directory stays sorted.
    function _updateIndices(uint256 dir, Move[] memory moves) private {
        for (uint256 i; i < moves.length; ++i) {
            Move memory m = moves[i];
            if (m.from == AT_HOME || m.to == AT_HOME || m.from == m.to) continue;

            LibDirectory.setIndex(dir, m.position, m.to);
        }
    }

    /// Rebuilds the directory if entries were packed or evicted: evicted entries are dropped
    /// from it and newly packed ones merged in by fingerprint.
    function _rebuild(uint256 dir, Move[] memory moves) private {
        uint256 added;
        uint256 evicted;

        for (uint256 i; i < moves.length; ++i) {
            if (moves[i].from == AT_HOME) ++added;
            else if (moves[i].to == AT_HOME) ++evicted;
        }

        if (added == 0 && evicted == 0) return;
        if (LibDirectory.length(dir) - evicted + added > MAX_PACKED) revert DirectoryFull();

        (uint256[4] memory removed, uint256[] memory insertions) = _changes(moves, added);

        (bool collided, uint256 move, uint256 lastMove) =
            LibDirectory.rebuild(dir, removed, evicted, insertions);

        if (collided) _revertCollision(moves, move, lastMove);
    }

    /// The directory positions of evicted entries, and the directory entries of newly packed ones.
    function _changes(Move[] memory moves, uint256 added)
        private
        pure
        returns (uint256[4] memory removed, uint256[] memory insertions)
    {
        insertions = new uint256[](added);
        uint256 inserted;

        for (uint256 i; i < moves.length; ++i) {
            Move memory m = moves[i];

            if (m.to == AT_HOME) {
                _mark(removed, m.position);
            } else if (m.from == AT_HOME) {
                // Tagged with the move's number, so a collision can name its key.
                insertions[inserted++] = LibDirectory.taggedEntry(m.id, m.to, i);
            }
        }
    }

    /// Kept entries never share a fingerprint, so at least one side of a clash is an insertion.
    /// The other is ~0 if it was a kept entry. Only two insertions can be the same entry.
    function _revertCollision(Move[] memory moves, uint256 move, uint256 lastMove) private pure {
        uint256 kept = type(uint256).max;

        if (move != kept && lastMove != kept && moves[move].id == moves[lastMove].id) {
            revert DuplicateKey(moves[move].key);
        }

        revert FingerprintCollision(moves[move != kept ? move : lastMove].key);
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    /// Sets bit `index` and reports whether it was already set. Callers keep `index` below 1,024,
    /// so it always falls inside the four words.
    function _mark(uint256[4] memory bits, uint256 index) private pure returns (bool wasSet) {
        assembly ("memory-safe") {
            let location := add(bits, shl(5, shr(8, index)))
            let word := mload(location)
            let bit := shl(and(index, 255), 1)

            wasSet := iszero(iszero(and(word, bit)))
            mstore(location, or(word, bit))
        }
    }

    function _isMarked(uint256[4] memory bits, uint256 index) private pure returns (bool set) {
        assembly ("memory-safe") {
            set := and(shr(and(index, 255), mload(add(bits, shl(5, shr(8, index))))), 1)
        }
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _load(uint256 slot_) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := sload(slot_)
        }
    }

    function _store(uint256 slot_, uint256 value) private {
        assembly ("memory-safe") {
            sstore(slot_, value)
        }
    }
}
