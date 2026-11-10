// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LibDirectory} from "./LibDirectory.sol";

/// Fixed-size entries looked up by key, such as "balances" or "allowances".
///
/// Entries can only share a page with entries in the same map, so put entities that are used
/// together into one map. Entries of different sizes can share a map made with {mapOfKinds}:
/// the map lists each kind's size, and the top byte of a key names its kind.
///
/// The low byte holds flags: whether the map keeps home flags for HOME hints, and whether its
/// keys carry a kind. The next byte holds the map's entries per page, and the eight bytes above
/// it the size in slots of each kind, 0 for a kind the map doesn't have. A map of one kind keeps
/// its size as kind 0's. The rest is 176 bits of a hash of the map's name.
type PagedMap is bytes32;

/// A map of several kinds while its kinds are being listed. {PagePack.mapOfKinds} starts one,
/// {PagePack.withKind} adds to it and {PagePack.build} turns it into a PagedMap.
type MapBuilder is bytes32;

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
///   data, so a struct must be at most its entry's size: the map's width, or the size the map
///   lists for the key's kind. Take that size from the struct, or check it with {requireFits}.
///   Either way, measure the struct with a helper: in a `T[2] storage` array placed at slot 0,
///   element 1's slot is T's size in slots. Declare the helper `view`, not `pure`: the compiler
///   treats indexing a storage array as a possible read, though nothing is read.
/// - In a map of several kinds, the top byte of a key picks the entry and its size. Build it
///   from a constant and never from input: a caller who could set it would reach another kind's
///   entry, and a struct wider than that entry would overwrite its neighbours. {kindKey} and
///   {hashedKindKey} build keys that keep their input out of that byte.
/// - They go stale when the map is rebalanced, even by a request that doesn't name the entry:
///   making room on a page can move the data of the entries staying on it. Look the entry up
///   again, and lay the struct over it again, after anything in the same transaction that could
///   rebalance, including an external call that might re-enter. If a callback could reach a
///   function that rebalances, guard it and the functions holding entries with one lock.
/// - Entries hold fixed-size values only. Mappings, dynamic arrays, strings and bytes keep their
///   contents at slots derived from the entry's location, so a move would leave them behind.
///   Keep such data in its own storage, keyed by the entry's key.
type Entry is uint256;

using PagePack for PagedMap global;
using PagePack for MapBuilder global;
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
/// An entry's size is never passed in: it is the map's width, or in a map of several kinds the
/// size the map lists for the kind in the key's top byte. So a lookup, a hint and a placement
/// name an entry by its key alone, and can't disagree about how big it is.
///
/// Each map keeps one directory page mapping a short fingerprint of every packed entry to its
/// index. A lookup without a hint searches the directory, paying for that page once per
/// transaction. A lookup with a correct hint skips the directory entirely: a packed index is
/// checked against its tag, and a HOME hint (home-hint maps only) against the flag.
///
/// A hint is a packed index plus one, or HOME. It reaches a lookup in one of two ways: passed to
/// {find}(key, hint), or loaded once with {useHints}, which keeps it in transient storage for
/// the rest of the transaction, where {find}(key) looks for it. A loaded hint is stored under
/// its entry's fingerprint, not its key, so calldata carries 5 bytes per hint and no keys. A
/// hint passed to a lookup needs no fingerprint, and travels as 2 bytes ({hintsOf}, {hintAt}).
/// Entries that share a fingerprint share the hint, which is safe because a hint only says
/// where to look: every hint, however it arrived, is checked against the tag or the flag. One
/// that is wrong, stale or meant for another entry costs a directory search and never returns
/// the wrong entry.
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
/// Transient storage of a map, until the transaction ends:
///
///   D + fingerprint    the hint loaded for entries with that 22-bit fingerprint, 0 for none
///
/// A tag is the entry's identity with its low 14 bits replaced by where its data starts on the
/// page (bits 7 to 13) and its size in slots (bits 0 to 6). Lookups only ever read tags from the
/// tag region, so nothing written into an entry's data can pose as a tag.
library PagePack {
    /// Puts the entry for `key` at packed `index`, or sends it home if `index` is HOME.
    struct Placement {
        bytes32 key;
        uint256 index;
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
    error InvalidKind(uint256 kind);
    error UnknownKind(uint256 kind);
    error NoKinds();
    error KeyTooLong(uint256 value);
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

    /// Kinds a map of several kinds can list, numbered from 0.
    uint256 internal constant MAX_KINDS = 8;

    // The low byte of a map: a bit for maps that keep home flags, and one for maps whose keys
    // carry a kind. The byte above holds the map's entries per page, and the eight above that
    // each kind's size.
    uint256 private constant HOME_HINTS = 0x80;
    uint256 private constant KINDED = 0x40;
    uint256 private constant PER_PAGE_SHIFT = 8;
    uint256 private constant PER_PAGE_BYTE = 0xff00;
    uint256 private constant SIZES_SHIFT = 16;
    uint256 private constant HANDLE_FIELDS = (1 << 80) - 1;

    // Tables of numbers below 2^16 hold 16 to a word. See {_setNumber}.
    uint256 private constant NUMBERS_PER_WORD = 16;

    // Every entry on a page needs a data slot as well as a tag.
    uint256 private constant MAX_PER_PAGE = PAGE_SIZE / 2;

    // A hint is index + 1 or HOME. Plain literals, so that inline assembly can use them.
    uint256 private constant INDEX_LIMIT = 1024;
    uint256 private constant HOME_HINT = 1025;

    // A loaded hint's transient slot is the directory's plus the entry's fingerprint: the top 22
    // bits of its identity, as LibDirectory takes them. In calldata it is 5 bytes: the
    // fingerprint above the hint, which fits 11 bits.
    uint256 private constant FINGERPRINT_SHIFT = 234;
    uint256 private constant HINT_BITS = 11;
    uint256 private constant HINT_MASK = 0x7ff;
    uint256 private constant PACKED_HINT_BYTES = 5;

    // A tag's low 14 bits: where the entry's data starts on its page, and its size. The bits
    // above are the entry's identity.
    uint256 private constant TAG_OFFSET_SHIFT = 7;
    uint256 private constant TAG_FIELD_MASK = 0x7f;
    uint256 private constant TAG_IDENTITY_SHIFT = 14;

    // A move's position when the entry is at home.
    uint256 private constant AT_HOME = type(uint256).max;

    // What a page search returns when no run of free slots is long enough.
    uint256 private constant NO_FIT = 0xffff;

    // Set above the 128 slot bits of a page's bitmap of slots in use, once the page has to
    // compact.
    uint256 private constant COMPACTS = 1 << PAGE_SIZE;

    // ------------------------------------------------------------------------------------------
    // Maps
    // ------------------------------------------------------------------------------------------

    /// @notice Creates a map of entries that are `slots` slots wide.
    /// @dev Intended for an immutable: `PagedMap immutable BALANCES = PagePack.map("x", 1);`
    ///      Keys are any 32 bytes. For entries of several sizes, see {mapOfKinds}.
    function map(string memory name, uint256 slots) internal pure returns (PagedMap) {
        return _withKind(_named(name, 0), 0, slots).build();
    }

    /// @notice Like {map}, but packed entries leave a flag on their home page, so a HOME hint
    ///         can confirm an entry isn't packed without loading the directory.
    /// @dev The flag is one live storage slot on every packed entry's home page, so packing no
    ///      longer empties those pages. Use this when transactions often touch entries that
    ///      aren't packed and nothing else loads the directory. The choice is part of the map,
    ///      like its width: the two kinds of map never share storage.
    function mapWithHomeHints(string memory name, uint256 slots) internal pure returns (PagedMap) {
        return _withKind(_named(name, HOME_HINTS), 0, slots).build();
    }

    /// @notice Starts a map for entries of several sizes. List each kind of entry and its size
    ///         with {withKind}, then {build} the map. The top byte of a key names its kind:
    ///
    ///             PagePack.mapOfKinds("token.accounts")
    ///                 .withKind(APPROVAL, approvalSlots())
    ///                 .withKind(ACCOUNT, accountSlots())
    ///                 .build();
    ///
    /// @dev An entry's size comes from its key and the map, so lookups, hints and placements
    ///      never pass one. Keys are a kind in the top byte over 31 bytes of the caller's
    ///      choosing: build them with {kindKey}, or {hashedKindKey} for a key that needs more.
    ///
    ///      A map lists at most 8 kinds, numbered 0 to 7, each 1 to 127 slots wide. Kinds of
    ///      the same size can share a number and tell their keys apart in the next byte. The
    ///      kinds are part of the map: a map with another list of them never shares storage
    ///      with this one, so they can't change once the map holds entries.
    function mapOfKinds(string memory name) internal pure returns (MapBuilder) {
        return _named(name, KINDED);
    }

    /// @notice Like {mapOfKinds}, keeping home flags for HOME hints. See {mapWithHomeHints}.
    function mapOfKindsWithHomeHints(string memory name) internal pure returns (MapBuilder) {
        return _named(name, KINDED | HOME_HINTS);
    }

    /// @notice Adds kind number `kind`, of entries `slots` slots wide. Kinds can be listed in
    ///         any order.
    /// @dev Reverts if the kind is above 7 or already listed.
    function withKind(MapBuilder b, uint256 kind, uint256 slots)
        internal
        pure
        returns (MapBuilder)
    {
        if (
            kind >= MAX_KINDS
                || (uint256(MapBuilder.unwrap(b)) >> (SIZES_SHIFT + 8 * kind)) & 0xff != 0
        ) {
            revert InvalidKind(kind);
        }

        return _withKind(b, kind, slots);
    }

    /// @notice The map with the kinds listed. Reverts if there are none.
    /// @dev Its entries per page is the count that fits its kinds in equal numbers: 50 for
    ///      kinds of one and two slots, 25 of each. Kinds too wide to fit one of each get as
    ///      many of the widest as fit. {withEntriesPerPage} sets another count.
    function build(MapBuilder b) internal pure returns (PagedMap) {
        uint256 handle = uint256(MapBuilder.unwrap(b));
        (uint256 count, uint256 total, uint256 widest) = _kinds(handle);

        if (count == 0) revert NoKinds();

        // Whole groups of one entry of each kind, so the division rounds down first.
        // forge-lint: disable-next-line(divide-before-multiply)
        uint256 perPage = (PAGE_SIZE / total) * count;
        if (perPage == 0) perPage = PAGE_SIZE / (widest + 1);

        return PagedMap.wrap(bytes32(handle | (perPage << PER_PAGE_SHIFT)));
    }

    /// @notice The same map with `perPage` packed indices, and so tags, on each page: 1 to 64.
    ///         The page's other `128 - perPage` slots hold its entries' data.
    /// @dev Pick it for the mix the planner packs, when the default doesn't suit: as many
    ///      entries as fit of a map's one size, or of each of its kinds in equal numbers. Every
    ///      size the map has must fit the data slots left. Part of the map, like its sizes: a
    ///      map with another count never shares storage with this one. Setting the default
    ///      count changes nothing.
    function withEntriesPerPage(PagedMap m, uint256 perPage) internal pure returns (PagedMap) {
        uint256 handle = uint256(PagedMap.unwrap(m));
        (,, uint256 widest) = _kinds(handle);

        if (perPage == 0 || perPage > MAX_PER_PAGE || widest > PAGE_SIZE - perPage) {
            revert InvalidEntriesPerPage(perPage);
        }

        return PagedMap.wrap(bytes32((handle & ~PER_PAGE_BYTE) | (perPage << PER_PAGE_SHIFT)));
    }

    function _named(string memory name, uint256 flags) private pure returns (MapBuilder) {
        return MapBuilder.wrap(bytes32((uint256(keccak256(bytes(name))) & ~HANDLE_FIELDS) | flags));
    }

    function _withKind(MapBuilder b, uint256 kind, uint256 slots)
        private
        pure
        returns (MapBuilder)
    {
        if (slots == 0 || slots > MAX_WIDTH) revert InvalidWidth(slots);

        return MapBuilder.wrap(
            bytes32(uint256(MapBuilder.unwrap(b)) | (slots << (SIZES_SHIFT + 8 * kind)))
        );
    }

    /// How many kinds a handle lists, their sizes plus a tag each, and the widest.
    function _kinds(uint256 handle)
        private
        pure
        returns (uint256 count, uint256 total, uint256 widest)
    {
        for (uint256 kind; kind < MAX_KINDS; ++kind) {
            uint256 slots = (handle >> (SIZES_SHIFT + 8 * kind)) & 0xff;
            if (slots == 0) continue;

            ++count;
            total += slots + 1;
            if (slots > widest) widest = slots;
        }
    }

    /// @notice Number of data slots in each entry of a map of one kind: its width. In a map of
    ///         several kinds, kind 0's size, or 0 if it has no kind 0: see {slotsOf}.
    function width(PagedMap m) internal pure returns (uint256) {
        return slotsOf(m, 0);
    }

    /// @notice Number of data slots in each entry of `kind`, or 0 if the map has no such kind.
    function slotsOf(PagedMap m, uint256 kind) internal pure returns (uint256 slots) {
        assembly ("memory-safe") {
            if lt(kind, MAX_KINDS) { slots := and(shr(add(SIZES_SHIFT, shl(3, kind)), m), 0xff) }
        }
    }

    /// @notice Number of data slots in the entry for `key`: the map's width, or in a map of
    ///         several kinds the size of the kind in the key's top byte. Reverts if the map has
    ///         no such kind.
    function sizeOf(PagedMap m, bytes32 key) internal pure returns (uint256 slots) {
        uint256 kind;

        assembly ("memory-safe") {
            if and(m, KINDED) { kind := byte(0, key) }
            if lt(kind, MAX_KINDS) {
                slots := and(shr(add(SIZES_SHIFT, shl(3, kind)), m), 0xff)
            }
        }

        if (slots == 0) revert UnknownKind(kind);
    }

    /// @notice Reverts unless a struct of `slots` slots fits within the map's width.
    /// @dev For a map of one kind whose width is set by hand, such as one pinned to the size of
    ///      its largest struct: check each struct's size when creating the map. A narrower
    ///      struct leaves the rest of its entry unused; a wider one would write into the next
    ///      packed entry. In a map of several kinds this checks kind 0 only: use
    ///      {requireFits}(kind, slots).
    function requireFits(PagedMap m, uint256 slots) internal pure {
        if (slots > m.width()) revert StructTooWide(slots, m.width());
    }

    /// @notice Reverts unless a struct of `slots` slots fits within entries of `kind`, which
    ///         also catches a kind the map doesn't list.
    /// @dev For a map of several kinds whose sizes are set by hand. A map that takes each
    ///      kind's size from its struct needs no check.
    function requireFits(PagedMap m, uint256 kind, uint256 slots) internal pure {
        if (slots > m.slotsOf(kind)) revert StructTooWide(slots, m.slotsOf(kind));
    }

    // ------------------------------------------------------------------------------------------
    // Keys
    // ------------------------------------------------------------------------------------------

    /// @notice A key of `kind` for `value`: the kind in the top byte over the value, which must
    ///         fit the 31 bytes below it.
    /// @dev The kind picks the entry's size, so take it from a constant, the one given to
    ///      {withKind}, and build keys here rather than by hand: a value that reached the top
    ///      byte would name another kind's entry. Reverts if it would, and never cuts the value
    ///      short, which would make two values share an entry. Hash a longer key and use
    ///      {hashedKindKey}. Only the kind's low byte is used.
    function kindKey(uint256 kind, uint256 value) internal pure returns (bytes32 key) {
        if (value >> 248 != 0) revert KeyTooLong(value);

        assembly ("memory-safe") {
            key := or(shl(248, kind), value)
        }
    }

    /// @notice A key of `kind` for a hash: the kind in the top byte over the hash's first 31
    ///         bytes.
    /// @dev For keys longer than 31 bytes, such as a pair of addresses. Two inputs share a key
    ///      only if their hashes agree on 248 bits, which takes about 2^124 tries to find. Only
    ///      the kind's low byte is used.
    function hashedKindKey(uint256 kind, bytes32 hash) internal pure returns (bytes32 key) {
        assembly ("memory-safe") {
            key := or(shl(248, kind), shr(8, hash))
        }
    }

    /// @notice Whether the map keeps home flags, so HOME hints work.
    function homeHints(PagedMap m) internal pure returns (bool) {
        return uint256(PagedMap.unwrap(m)) & HOME_HINTS != 0;
    }

    /// @notice Number of packed indices on one page: by default, as many entries as fit on a
    ///         page, each with its tag, taking a map's kinds in equal numbers.
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
    ///
    ///      A loaded hint is read from transient storage at the directory's slot plus the key's
    ///      fingerprint, so it may have been loaded for another key with that fingerprint, or
    ///      hold anything a caller sent. It is trusted no further than a hint passed to
    ///      {find}(key, hint): a packed index must hold a tag with this key's identity, and HOME
    ///      needs the key's home flag clear. Anything else falls through to the directory.
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
            dir := and(keccak256(0x00, 0x20), not(127))
            perPage := and(shr(PER_PAGE_SHIFT, m), 0xff)

            let hint := tload(add(dir, shr(FINGERPRINT_SHIFT, id)))

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
            // hint - 1 wraps to a huge number when hint is 0, so one comparison rejects both
            // "no hint" and out-of-range hints.
            let index := sub(hint, 1)

            mstore(0x00, m)
            mstore(0x20, key)

            switch lt(index, INDEX_LIMIT)
            case 1 {
                let id := keccak256(0x00, 0x40)
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
    /// @dev `hints` is a run of 5-byte hints in any order, as {packedHintsOf} builds it. Each is
    ///      big-endian: 7 zero bits, the entry's 22-bit fingerprint, then an 11-bit hint, the
    ///      entry's packed index plus one or HOME. One run can hold hints for entries of every
    ///      kind, but for one map only: call this once for each map.
    ///
    ///      Each hint is kept in transient storage at the directory's slot plus its fingerprint
    ///      and vanishes when the transaction ends. Checking for one costs {find} about 100 gas.
    ///
    ///      Nothing here is checked, because {find} checks every hint it reads against the
    ///      entry's tag or home flag. So a hint that is wrong, stale, out of range, or loaded for
    ///      another key with the same fingerprint costs a directory search and never returns the
    ///      wrong entry. Of two hints with one fingerprint the later is kept. Bytes left after
    ///      the last whole hint are ignored, and a hint with any of its top 7 bits set lands in a
    ///      slot no lookup reads.
    function useHints(PagedMap m, bytes calldata hints) internal {
        uint256 dir = _directory(m);

        assembly ("memory-safe") {
            // Whole hints only. Each is the top 5 bytes of the word loaded at its start.
            let whole := sub(hints.length, mod(hints.length, PACKED_HINT_BYTES))
            let end := add(hints.offset, whole)

            for { let p := hints.offset } lt(p, end) { p := add(p, PACKED_HINT_BYTES) } {
                let hint := shr(216, calldataload(p))
                tstore(add(dir, shr(HINT_BITS, hint)), and(hint, HINT_MASK))
            }
        }
    }

    /// @notice Remembers one hint, as {hintOf} returns it, for the rest of the transaction. See
    ///         {useHints}.
    function useHint(PagedMap m, bytes32 key, uint256 hint) internal {
        uint256 dir = _directory(m);
        uint256 fingerprint = m.fingerprintOf(key);

        assembly ("memory-safe") {
            tstore(add(dir, fingerprint), hint)
        }
    }

    /// @notice The hint for `key`: its packed index plus one. An entry that isn't packed has
    ///         HOME in a home-hint map, and 0 (no hint) elsewhere.
    /// @dev The value {find}(key, hint) takes. Meant to be called offchain (via an eth_call
    ///      wrapper). {hintsOf} returns it for a list of keys, 2 bytes each.
    /// @return The hint as a number, at most 1,025, so it fits 2 bytes.
    function hintOf(PagedMap m, bytes32 key) internal view returns (uint256) {
        return _hintOf(m, _identity(m, key));
    }

    /// @notice The hint for `key` as the 5 bytes {useHints} takes: the key's fingerprint above
    ///         its {hintOf}. Zero if there is no hint to give: an entry that isn't packed, in a
    ///         map without home flags.
    /// @dev Meant to be called offchain. A real packed hint is never zero.
    /// @return 5 bytes, or 0 for no hint.
    function packedHintOf(PagedMap m, bytes32 key) internal view returns (bytes5) {
        uint256 id = _identity(m, key);
        uint256 hint = _hintOf(m, id);

        if (hint == 0) return 0;

        // A 22-bit fingerprint above an 11-bit hint is 33 bits, so the cast drops nothing.
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes5(uint40((LibDirectory.fingerprintOf(id) << HINT_BITS) | hint));
    }

    /// @notice The packed hints for `keys`, joined into the bytes {useHints} takes. Keys with no
    ///         hint to give are left out, so the result can be shorter than 5 bytes a key.
    /// @dev Meant to be called offchain: expose it in an external view function, and one
    ///      eth_call builds a transaction's hints. Keys can be of any kind, in any order.
    /// @return hints 5 bytes for each key that has a hint, in the order of `keys`: at most
    ///         `5 * keys.length` bytes.
    function packedHintsOf(PagedMap m, bytes32[] memory keys)
        internal
        view
        returns (bytes memory hints)
    {
        // 27 spare bytes, so each hint can be written as a whole word.
        hints = new bytes(PACKED_HINT_BYTES * keys.length + 27);
        uint256 length;

        for (uint256 i; i < keys.length; ++i) {
            bytes5 hint = m.packedHintOf(keys[i]);
            if (hint == 0) continue;

            assembly ("memory-safe") {
                mstore(add(add(hints, 0x20), length), hint)
            }

            length += PACKED_HINT_BYTES;
        }

        assembly ("memory-safe") {
            mstore(hints, length)
        }
    }

    /// @notice The hints for `keys` as the bytes {hintAt} reads: each key's {hintOf} in 2 bytes,
    ///         big-endian, in the order of `keys`. A key with no hint still takes its 2 bytes,
    ///         as zero, so every hint stays at its key's position.
    /// @dev Meant to be called offchain: expose it in an external view function, and one
    ///      eth_call builds a transaction's hints. Pass the keys in the order the function
    ///      looks them up.
    /// @return hints 2 bytes for each key, in the order of `keys`: `2 * keys.length` bytes.
    function hintsOf(PagedMap m, bytes32[] memory keys) internal view returns (bytes memory hints) {
        hints = new bytes(2 * keys.length);

        for (uint256 i; i < keys.length; ++i) {
            uint256 hint = m.hintOf(keys[i]);

            // The hint's high byte, then its low byte: mstore8 stores the lowest byte.
            assembly ("memory-safe") {
                let at := add(add(hints, 0x20), shl(1, i))
                mstore8(at, shr(8, hint))
                mstore8(add(at, 1), hint)
            }
        }
    }

    /// @notice Hint `i` in a run of 2-byte hints, or 0 (no hint) past its end. For a function
    ///         that already loops over its keys and gives each lookup its own hint:
    ///
    ///             BALANCES.find(keys[i], PagePack.hintAt(hints, i));
    ///
    /// @dev Each hint is its key's {hintOf}, big-endian, in the order the function looks its
    ///      keys up, as {hintsOf} builds them. Costs less than {useHints}, which stores each
    ///      hint and reads it back, but only fits calls whose lookups follow an order the
    ///      caller knows. A caller can send fewer hints than keys, or none.
    /// @return hint The hint as a number, read from 2 bytes.
    function hintAt(bytes calldata hints, uint256 i) internal pure returns (uint256 hint) {
        // Runs for every lookup of a batch, so the bounds check multiplies rather than
        // branches: a branch costs more, and keeps the compiler from inlining this.
        assembly ("memory-safe") {
            let within := lt(i, shr(1, hints.length))
            hint := mul(within, shr(240, calldataload(add(hints.offset, shl(1, i)))))
        }
    }

    /// The hint for the entry with `id`. See {hintOf}.
    function _hintOf(PagedMap m, uint256 id) private view returns (uint256) {
        (uint256 index,,) = _locate(_directory(m), m.entriesPerPage(), id);

        if (index != AT_HOME) return index + 1;
        return m.homeHints() ? HOME : 0;
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
    ///      index is HOME. Entries that aren't named keep their indices, and so their hints, but
    ///      their data can move (see below): treat every rebalance as moving every entry in the
    ///      map, and look entries up again after it. The request describes which entry holds
    ///      each index after the call, so its order doesn't change that, and swaps and cycles
    ///      work: a placement may target an index whose entry is evicted or placed elsewhere in
    ///      the same call. Placing an entry at the index it already holds does nothing, so a
    ///      caller can resubmit a layout cheaply.
    ///
    ///      A placement names its entry by key alone. The entry's size is the map's width, or
    ///      in a map of several kinds the size of the kind in the key's top byte.
    ///
    ///      The call picks each arriving entry's data slots: the first gap on the page that
    ///      fits, in placement order, so the order can change where data lands and what the call
    ///      costs. An entry moving to another index on the same page keeps its data where it is.
    ///      If no gap fits but the page has enough free slots, the data of the entries staying on
    ///      the page is moved together first, though no request named them; their indices, and
    ///      so their hints, don't change. A page fits a layout if the sizes of its entries add up
    ///      to at most {dataSlotsPerPage}.
    ///
    ///      Reverts if a key is named twice, a key's kind isn't one the map has, an eviction
    ///      names an entry that isn't packed, two placements share an index, a placement targets
    ///      an index held by an entry the call doesn't move, a page's entries don't fit it, two
    ///      packed entries would share a fingerprint, or the directory would overflow.
    ///
    ///      Packing an entry from home costs about 61,000 gas, mostly MIP-8's charge for two new
    ///      slots, so split large layouts across transactions. Each page that receives entries
    ///      also has its tags read once, about 200 gas per index, and a page whose entries are
    ///      moved together costs 6,000 to 7,000 more for each entry moved, however large the
    ///      request. The sort of newly packed entries returns early if the caller lists them in
    ///      fingerprint order ({fingerprintOf}).
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
        // No moves yet, and room for one for each placement.
        moves = _withRoom(moves, placements.length);

        // Bitmaps over packed indices: those holding an entry this call names, and those a
        // placement targets. Indices are below 1,024, so four words cover them.
        uint256[4] memory named;
        uint256[4] memory claimed;

        for (uint256 i; i < placements.length; ++i) {
            Placement memory p = placements[i];
            (uint256 id, uint256 slots, bool inPlace) = _check(m, dir, perPage, p, named, claimed);

            if (!inPlace) _addMove(moves, dir, perPage, p, id, slots, named);
        }

        // A target must be empty or hold an entry this call names. Since no two placements share
        // a target, a named occupant is always leaving.
        for (uint256 i; i < moves.length; ++i) {
            uint256 index = moves[i].to;
            if (index == AT_HOME) continue;

            if (!_isMarked(named, index) && _load(_tagSlot(dir, perPage, index)) != 0) {
                revert IndexTaken(index);
            }
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
        // Runs for every placement, including each one of a resubmitted layout, so it is
        // assembly: the entry's size and identity, and whether its target already holds it.
        assembly ("memory-safe") {
            let key := mload(p)
            let kind := 0

            if and(m, KINDED) { kind := byte(0, key) }
            if lt(kind, MAX_KINDS) {
                slots := and(shr(add(SIZES_SHIFT, shl(3, kind)), m), 0xff)
            }

            mstore(0x00, m)
            mstore(0x20, key)
            id := keccak256(0x00, 0x40)

            let index := mload(add(p, 0x20))

            if lt(index, INDEX_LIMIT) {
                let page := add(dir, shl(7, add(div(index, perPage), 1)))
                let tag := sload(add(page, mod(index, perPage)))

                inPlace := eq(shr(TAG_IDENTITY_SHIFT, tag), shr(TAG_IDENTITY_SHIFT, id))
            }
        }

        // Every size a map lists fits its pages, so only a kind it doesn't list is rejected.
        if (slots == 0) revert UnknownKind(uint256(p.key) >> 248);
        if (p.index == HOME) return (id, slots, false);

        if (p.index >= MAX_INDEX) revert IndexOutOfRange(p.index);
        if (_mark(claimed, p.index)) revert IndexTaken(p.index);

        // A resubmitted entry is usually already in place, which also skips the search.
        if (inPlace && _mark(named, p.index)) revert DuplicateKey(p.key);
    }

    /// Adds the move a checked placement makes to `moves`. Until {_allocate} picks its slots, a
    /// move's data goes to the entry's home.
    ///
    /// The move is added rather than returned: a function that returns a move starts with an
    /// empty one allocated for it, which costs about as much as the move itself.
    function _addMove(
        Move[] memory moves,
        uint256 dir,
        uint256 perPage,
        Placement memory p,
        uint256 id,
        uint256 slots,
        uint256[4] memory named
    ) private view {
        (uint256 from, uint256 position, uint256 source) = _locate(dir, perPage, id);

        if (from == AT_HOME) {
            if (p.index == HOME) revert NotPacked(p.key);
        } else if (_mark(named, from)) {
            revert DuplicateKey(p.key);
        }

        uint256 to = p.index == HOME ? AT_HOME : p.index;

        _append(moves, Move(p.key, id, slots, from, to, position, source, _home(id)));
    }

    // ------------------------------------------------------------------------------------------
    // Allocation
    // ------------------------------------------------------------------------------------------

    /// Picks the data slots of every move to a packed index. An entry moving within its page
    /// keeps its data; entries arriving on a page take its gaps, first fit in placement order.
    /// A page with room for an arriving entry but no gap that fits it compacts: see {_compact}.
    /// Returns the moves, plus a move for each staying entry that a compacting page shifts.
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
        uint256 compacting;

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
                uint256 free = _countFree(pageUsed);
                if (free < move.slots) revert PageFull(page);

                // The page compacts. {_compact} lays it out once every entry has its slots:
                // all that is on the page so far will sit together from its first slot, so this
                // entry goes straight after. That leaves the page's free slots in one run at its
                // end, where a later entry either fits or finds the page full, so no page
                // compacts twice.
                offset = PAGE_SIZE - free;
                pageUsed = COMPACTS | _range(0, offset);
                ++compacting;
            }

            move.target = start + offset;
            used[page] = pageUsed | _range(offset, move.slots);
        }

        if (compacting == 0) return moves;

        return _compact(dir, perPage, moves, used, leaving, compacting);
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

    /// Lays out the `pages` pages that {_allocate} marked COMPACTS in `used`: each had room for
    /// an arriving entry but no gap that fit it. The data of the entries staying on such a page
    /// slides down against the tag region, in the order it sits, and the entries arriving on the
    /// page follow in placement order. Returns the moves, with a move added for each staying
    /// entry that slides and that the request didn't name.
    ///
    /// Goes through the moves twice, however many pages compact. Beyond that each page costs
    /// what the page holds, whatever else the request does.
    function _compact(
        uint256 dir,
        uint256 perPage,
        Move[] memory moves,
        uint256[] memory used,
        uint256[4] memory leaving,
        uint256 pages
    ) private view returns (Move[] memory grown) {
        // Room for a move for every index on those pages.
        grown = _withRoom(moves, pages * perPage);

        // The number, plus one, of the move leaving each packed index. A request makes fewer
        // than 2^16 moves: at most one to each index, and one home from each.
        uint256[] memory byFrom = new uint256[](MAX_INDEX / NUMBERS_PER_WORD);

        for (uint256 i; i < moves.length; ++i) {
            uint256 from = moves[i].from;
            if (from != AT_HOME) _setNumber(byFrom, from, i + 1);
        }

        // The first free slot of each page laid out so far.
        uint256[] memory next = new uint256[](used.length);

        for (uint256 i; i < moves.length; ++i) {
            Move memory move = moves[i];
            if (!_arrives(move, perPage)) continue;

            uint256 page = move.to / perPage;
            if (used[page] & COMPACTS == 0) continue;

            uint256 start = dir + ((page + 1) << 7);

            if (next[page] == 0) {
                uint256[] memory byOffset = _staying(start, perPage, page, leaving);
                next[page] = _slide(start, perPage, byOffset, grown, byFrom);
            }

            move.target = start + next[page];
            next[page] += move.slots;
        }
    }

    /// The index, plus one, of each entry staying on a page, by where on the page its data
    /// starts: a table of numbers, as {_setNumber} keeps them.
    function _staying(uint256 start, uint256 perPage, uint256 page, uint256[4] memory leaving)
        private
        view
        returns (uint256[] memory byOffset)
    {
        byOffset = new uint256[](PAGE_SIZE / NUMBERS_PER_WORD);

        uint256 first = page * perPage;
        uint256 end = _min(first + perPage, MAX_INDEX);

        for (uint256 index = first; index < end; ++index) {
            uint256 tag = _load(start + index - first);

            if (tag != 0 && !_isMarked(leaving, index)) {
                _setNumber(byOffset, _offsetOf(tag), index + 1);
            }
        }
    }

    /// Lays the entries staying on the page at `start` out one after another from the end of its
    /// tag region, in the order their data sits, and returns the first slot after them. An entry
    /// already in place needs nothing. One that slides has its move retargeted if the request
    /// moves it within the page, and otherwise gets a move of its own, added to `moves`.
    function _slide(
        uint256 start,
        uint256 perPage,
        uint256[] memory byOffset,
        Move[] memory moves,
        uint256[] memory byFrom
    ) private view returns (uint256 next) {
        next = perPage;

        for (uint256 offset = perPage; offset < PAGE_SIZE; ++offset) {
            uint256 index = _number(byOffset, offset);
            if (index == 0) continue;

            --index;
            uint256 tag = _load(start + index % perPage);

            if (offset != next) {
                uint256 mover = _number(byFrom, index);

                if (mover != 0) {
                    moves[mover - 1].target = start + next;
                } else {
                    _addShift(moves, start + offset, start + next, tag, index);
                }
            }

            next += tag & TAG_FIELD_MASK;
        }
    }

    /// Adds a move of the data of an entry the request didn't name. The entry keeps its index and
    /// gets a new tag, for which its old tag's identity bits are all it needs. Added rather than
    /// returned, as in {_addMove}.
    function _addShift(
        Move[] memory moves,
        uint256 source,
        uint256 target,
        uint256 tag,
        uint256 index
    ) private pure {
        _append(moves, Move(bytes32(0), tag, tag & TAG_FIELD_MASK, index, index, 0, source, target));
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
    /// handle in means the same key in two maps never collides, and the result is never zero in
    /// practice, so a zero tag can mark an empty index.
    function _identity(PagedMap m, bytes32 key) private pure returns (uint256 id) {
        assembly ("memory-safe") {
            mstore(0x00, m)
            mstore(0x20, key)
            id := keccak256(0x00, 0x40)
        }
    }

    function _directory(PagedMap m) private pure returns (uint256 dir) {
        assembly ("memory-safe") {
            mstore(0x00, m)
            dir := and(keccak256(0x00, 0x20), not(127))
        }
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

    /// A list of the same moves with room to {_append} `extra` more.
    function _withRoom(Move[] memory moves, uint256 extra)
        private
        pure
        returns (Move[] memory list)
    {
        // Allocated as words: a new array of moves would come with a move for every element.
        uint256[] memory words = new uint256[](moves.length + extra);

        assembly ("memory-safe") {
            let count := mload(moves)

            mcopy(add(words, 0x20), add(moves, 0x20), shl(5, count))
            mstore(words, count)
            list := words
        }
    }

    /// Adds `move` to a list made {_withRoom} for it.
    function _append(Move[] memory moves, Move memory move) private pure {
        assembly ("memory-safe") {
            let count := add(mload(moves), 1)

            mstore(moves, count)
            mstore(add(moves, shl(5, count)), move)
        }
    }

    /// Sets number `at` in a table of 16-bit numbers, kept 16 to a word. Callers keep `at`
    /// inside the table and `value` below 2^16.
    function _setNumber(uint256[] memory table, uint256 at, uint256 value) private pure {
        assembly ("memory-safe") {
            let location := add(add(table, 0x20), shl(5, shr(4, at)))
            let shift := shl(4, and(at, 15))
            let word := mload(location)

            // Flips the bits in which the number held differs from `value`.
            mstore(location, xor(word, shl(shift, xor(and(shr(shift, word), 0xffff), value))))
        }
    }

    /// Number `at` in a table of 16-bit numbers. See {_setNumber}.
    function _number(uint256[] memory table, uint256 at) private pure returns (uint256 value) {
        assembly ("memory-safe") {
            let word := mload(add(add(table, 0x20), shl(5, shr(4, at))))

            value := and(shr(shl(4, and(at, 15)), word), 0xffff)
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
