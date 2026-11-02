// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LibDirectory} from "./LibDirectory.sol";

/// A family of fixed-width records, such as "balances" or "allowances".
///
/// Records can only share a page with records in the same space, so put entities that are used
/// together into one space. The low byte holds the record width in words (7 bits) and, in its top
/// bit, whether the space keeps home flags for HOME hints.
type Space is bytes32;

/// The first data word of a record, wherever the record currently lives.
///
/// Use it a word at a time with {read} and {write}, or lay a struct over it and let Solidity
/// handle the field offsets and packing:
///
///     Account storage account;
///     assembly ("memory-safe") {
///         account.slot := r
///     }
///
/// A Record is a raw storage pointer, and so is a struct laid over one. Nothing checks how they
/// are used:
/// - Offsets aren't bounds-checked. Offset `width` is already the next record's identity word,
///   so a struct must be exactly `width` words. Test each one: in a `T[2] storage` array placed
///   at slot 0, element 1's slot is T's size in words. Declare that helper `view`, not `pure`:
///   the compiler treats indexing a storage array as a possible read, though nothing is read.
/// - They go stale when the record moves. Look the record up again, and lay the struct over it
///   again, after anything in the same transaction that could rebalance, including an external
///   call that might re-enter.
/// - Records hold fixed-size values only. Mappings, dynamic arrays, strings and bytes keep their
///   contents at slots derived from the record's location, so a move would leave them behind.
///   Keep such data in its own storage, keyed by the record's key.
type Record is uint256;

using PagePack for Space global;
using PagePack for Record global;

/// @title PagePack
/// @notice Packs storage records that are used together onto shared MIP-8 pages.
///
/// MIP-8 prices storage by 128-slot page: the first touch of a page in a transaction costs
/// 8,100 gas and every later slot on it costs 100. A mapping puts each entry on its own page, so
/// touching N entries costs N page loads. PagePack lets an admin move hot records onto shared
/// pages, so a transaction touching N packed records on k pages pays for k loads instead.
///
/// A record lives in one of two places:
///
///   home     keccak256(space, key), rounded down to a page boundary. Every record starts here,
///            and it costs the same as a mapping entry. In a space made with
///            {spaceWithHomeHints}, the last slot of the home page holds a flag while the record
///            is packed.
///   packed   a numbered slot in the space's packed region, placed there by {rebalance}. Each
///            packed record is an identity word followed by its data, so a lookup can confirm it
///            found the right record.
///
/// Each space keeps one directory page mapping a short fingerprint of every packed record to its
/// index. A lookup without a hint searches the directory, paying for that page once per
/// transaction. A lookup with a correct hint skips the directory entirely: a packed index is
/// checked against the identity word, and a HOME hint (home-hint spaces only) against the flag.
///
/// Storage layout of a space, all page-aligned:
///
///   D = keccak256(space) rounded down to a page boundary
///   D + 0              number of packed records
///   D + 1 .. D + 127   directory entries, 8 per slot, sorted by fingerprint (see LibDirectory)
///   D + 128 ...        packed pages, floor(128 / (width + 1)) records each
library PagePack {
    struct Placement {
        bytes32 key;
        uint256 index;
    }

    struct Hint {
        bytes32 key;
        uint256 hint;
    }

    /// A record named in a rebalance: where it is and where it goes. Internal to {rebalance}.
    struct Move {
        bytes32 key;
        uint256 id;
        uint256 from;
        uint256 to;
        uint256 position;
    }

    error InvalidWidth(uint256 width);
    error IndexOutOfRange(uint256 index);
    error IndexTaken(uint256 index);
    error NotPacked(bytes32 key);
    error DuplicateKey(bytes32 key);
    error FingerprintCollision(bytes32 key);
    error DirectoryFull();

    uint256 internal constant PAGE_SIZE = 128;
    uint256 internal constant MAX_WIDTH = 127;

    /// Records a space's directory can list.
    uint256 internal constant MAX_PACKED = LibDirectory.CAPACITY;

    /// Packed indices are stored in 10 bits.
    uint256 internal constant MAX_INDEX = LibDirectory.INDEX_LIMIT;

    /// The hint for a record that isn't packed, in a space made with {spaceWithHomeHints}. Other
    /// spaces ignore it. Packed records' hints are index + 1, so they never reach it.
    uint256 internal constant HOME = MAX_INDEX + 1;

    // The low byte of a space: its width, and a bit for spaces that keep home flags.
    uint256 private constant WIDTH_MASK = 0x7f;
    uint256 private constant HOME_HINTS = 0x80;

    // A move's position when the record is at home.
    uint256 private constant AT_HOME = type(uint256).max;

    // ------------------------------------------------------------------------------------------
    // Spaces
    // ------------------------------------------------------------------------------------------

    /// @notice Creates a space of records that are `words` words wide.
    /// @dev Intended for an immutable: `Space immutable BALANCES = PagePack.space("x", 1);`
    function space(string memory name, uint256 words) internal pure returns (Space) {
        return _space(name, words, 0);
    }

    /// @notice Like {space}, but packed records leave a flag on their home page, so a HOME hint
    ///         can confirm a record isn't packed without loading the directory.
    /// @dev The flag is one live storage word on every packed record's home page, so packing no
    ///      longer empties those pages. Use this when transactions often touch records that
    ///      aren't packed and nothing else loads the directory. The choice is part of the space,
    ///      like its width: the two kinds of space never share storage.
    function spaceWithHomeHints(string memory name, uint256 words) internal pure returns (Space) {
        return _space(name, words, HOME_HINTS);
    }

    function _space(string memory name, uint256 words, uint256 mode) private pure returns (Space) {
        if (words == 0 || words > MAX_WIDTH) revert InvalidWidth(words);

        bytes32 base = keccak256(bytes(name)) & ~bytes32(uint256(0xff));
        return Space.wrap(base | bytes32(words | mode));
    }

    /// @notice Number of data words in each record.
    function width(Space s) internal pure returns (uint256) {
        return uint256(Space.unwrap(s)) & WIDTH_MASK;
    }

    /// @notice Whether the space keeps home flags, so HOME hints work.
    function homeHints(Space s) internal pure returns (bool) {
        return uint256(Space.unwrap(s)) & HOME_HINTS != 0;
    }

    /// @notice Number of packed records that fit on one page.
    function recordsPerPage(Space s) internal pure returns (uint256) {
        return PAGE_SIZE / (s.width() + 1);
    }

    /// @notice Number of records currently packed.
    function packedCount(Space s) internal view returns (uint256) {
        return LibDirectory.length(_directory(s));
    }

    /// @notice The 22-bit fingerprint the directory keeps for `key`.
    /// @dev Two records with the same fingerprint can't both be packed in one space. Planners
    ///      should check new placements against the packed set and leave one of any clashing pair
    ///      at home; with 1,016 random keys, about 1 layout in 9 contains such a pair.
    function fingerprintOf(Space s, bytes32 key) internal pure returns (uint256) {
        return LibDirectory.fingerprintOf(_identity(s, key));
    }

    // ------------------------------------------------------------------------------------------
    // Lookup
    // ------------------------------------------------------------------------------------------

    // Lookups run on every record access, so their arithmetic is unchecked. Widths are at most
    // 127, indices below 1024 and slots come from hashes, so none of it can overflow in practice.

    /// @notice Locates the record for `key`, using a hint from {useHints} if there is one.
    function find(Space s, bytes32 key) internal view returns (Record) {
        unchecked {
            uint256 id = _identity(s, key);
            uint256 hint;

            assembly ("memory-safe") {
                hint := tload(id)
            }

            uint256 dir = _directory(s);

            // The same checks as find(key, hint), repeated here to keep this hot path inline.
            // Most lookups have no hint, so they skip both checks with one comparison.
            if (hint != 0) {
                if (hint - 1 < MAX_INDEX) {
                    uint256 location = _packedSlot(dir, s.width() + 1, hint - 1);
                    if (_load(location) == id) return Record.wrap(location + 1);
                } else if (hint == HOME && s.homeHints()) {
                    if (_load(_packedFlag(id)) == 0) return Record.wrap(_home(id));
                }
            }

            (bool found, uint256 index,) = LibDirectory.search(dir, id);

            if (found) {
                uint256 location = _packedSlot(dir, s.width() + 1, index);

                // Fingerprints are short, so a match is only a candidate until the identity
                // agrees.
                if (_load(location) == id) return Record.wrap(location + 1);
            }

            return Record.wrap(_home(id));
        }
    }

    /// @notice Locates the record for `key`, checking `hint` before the directory.
    /// @dev A hint is the value returned by {hintOf}; 0 means no hint. A wrong or stale hint
    ///      falls back to the directory, so it can cost gas but never returns the wrong record.
    function find(Space s, bytes32 key, uint256 hint) internal view returns (Record) {
        unchecked {
            // hint - 1 wraps to a huge number when hint is 0, so one comparison rejects both
            // "no hint" and out-of-range hints.
            if (hint - 1 < MAX_INDEX) {
                uint256 location = _packedSlot(_directory(s), s.width() + 1, hint - 1);

                if (_load(location) == _identity(s, key)) return Record.wrap(location + 1);
            } else if (hint == HOME && s.homeHints()) {
                uint256 id = _identity(s, key);

                // The flag shares the home page, so this costs what a mapping entry does.
                if (_load(_packedFlag(id)) == 0) return Record.wrap(_home(id));
            }

            return find(s, key);
        }
    }

    /// @notice Remembers hints for the rest of the transaction, so {find} without a hint uses
    ///         them. Load a batch's hints once at the entry point instead of passing one to every
    ///         lookup.
    /// @dev Hints live in transient storage under each record's identity and vanish when the
    ///      transaction ends. Checking for one costs {find} about 100 gas. Wrong or stale hints
    ///      are as safe as they are with {find}(key, hint).
    function useHints(Space s, Hint[] calldata hints) internal {
        for (uint256 i; i < hints.length; ++i) {
            uint256 id = _identity(s, hints[i].key);
            uint256 hint = hints[i].hint;

            assembly ("memory-safe") {
                tstore(id, hint)
            }
        }
    }

    /// @notice Remembers one hint for the rest of the transaction. See {useHints}.
    function useHint(Space s, bytes32 key, uint256 hint) internal {
        uint256 id = _identity(s, key);

        assembly ("memory-safe") {
            tstore(id, hint)
        }
    }

    /// @notice The hint for `key`: its packed index plus one. A record that isn't packed has
    ///         HOME in a home-hint space, and 0 (no hint) elsewhere.
    /// @dev Meant to be called off-chain (via an eth_call wrapper) to build hints for a batch.
    function hintOf(Space s, bytes32 key) internal view returns (uint256) {
        (uint256 index,) = _locate(_directory(s), s.width() + 1, _identity(s, key));

        if (index != AT_HOME) return index + 1;

        return s.homeHints() ? HOME : 0;
    }

    // ------------------------------------------------------------------------------------------
    // Records
    // ------------------------------------------------------------------------------------------

    /// @notice Reads word `offset` of the record. Unchecked: keep `offset` below the width.
    function read(Record r, uint256 offset) internal view returns (uint256 value) {
        assembly ("memory-safe") {
            value := sload(add(r, offset))
        }
    }

    /// @notice Writes word `offset` of the record. Unchecked: keep `offset` below the width.
    function write(Record r, uint256 offset, uint256 value) internal {
        assembly ("memory-safe") {
            sstore(add(r, offset), value)
        }
    }

    /// @notice The storage slot of the record's first data word.
    function slot(Record r) internal pure returns (uint256) {
        return Record.unwrap(r);
    }

    // ------------------------------------------------------------------------------------------
    // Rebalancing
    // ------------------------------------------------------------------------------------------

    /// @notice Moves the named records to new positions in one atomic step.
    /// @dev Each eviction sends a packed record home and each placement puts a record at a packed
    ///      index. Records that aren't named stay where they are. The request describes the
    ///      layout after the call, so its order doesn't matter and swaps and cycles work: a
    ///      placement may target an index whose record is evicted or placed elsewhere in the same
    ///      call. Placing a record at the index it already holds does nothing, so a caller can
    ///      resubmit a layout cheaply.
    ///
    ///      Reverts if a key is named twice, an eviction names a record that isn't packed, two
    ///      placements share an index, a placement targets an index held by a record the call
    ///      doesn't move, two packed records would share a fingerprint, or the directory would
    ///      overflow.
    ///
    ///      Packing a record from home costs about 54,000 gas, mostly MIP-8's charge for two new
    ///      slots, so split large layouts across transactions. The sort of newly packed records
    ///      returns early if the caller lists them in fingerprint order ({fingerprintOf}).
    ///
    ///      There is no access control here: the calling contract decides who may rebalance.
    function rebalance(Space s, bytes32[] memory evictions, Placement[] memory placements)
        internal
    {
        if (evictions.length == 0 && placements.length == 0) return;

        uint256 dir = _directory(s);
        uint256 stride = s.width() + 1;

        (Move[] memory moves, uint256 added) = _plan(s, dir, stride, evictions, placements);

        _relocate(dir, stride, moves, s.homeHints());
        _updateIndices(dir, moves);

        if (evictions.length != 0 || added != 0) _rebuild(dir, moves, evictions.length, added);
    }

    /// Works out where each named record is and where it goes, and rejects any request that
    /// doesn't describe a valid layout. Records already in place need no move and are left out.
    /// Also returns how many records come from home.
    function _plan(
        Space s,
        uint256 dir,
        uint256 stride,
        bytes32[] memory evictions,
        Placement[] memory placements
    ) private view returns (Move[] memory moves, uint256 added) {
        moves = new Move[](evictions.length + placements.length);
        uint256 count;

        // Bitmaps over packed indices: those holding a record this call names, and those a
        // placement targets. Indices are below 1,024, so four words cover them.
        uint256[4] memory named;
        uint256[4] memory claimed;

        for (uint256 i; i < evictions.length; ++i) {
            bytes32 key = evictions[i];
            uint256 id = _identity(s, key);
            (uint256 from, uint256 position) = _locate(dir, stride, id);

            if (from == AT_HOME) revert NotPacked(key);
            if (_mark(named, from)) revert DuplicateKey(key);

            moves[count++] = Move(key, id, from, AT_HOME, position);
        }

        for (uint256 i; i < placements.length; ++i) {
            Placement memory p = placements[i];
            if (p.index >= MAX_INDEX) revert IndexOutOfRange(p.index);
            if (_mark(claimed, p.index)) revert IndexTaken(p.index);

            uint256 id = _identity(s, p.key);

            // A resubmitted record is usually already in place, which also skips the search.
            if (_load(_packedSlot(dir, stride, p.index)) == id) {
                if (_mark(named, p.index)) revert DuplicateKey(p.key);
                continue;
            }

            (uint256 from, uint256 position) = _locate(dir, stride, id);

            if (from == AT_HOME) ++added;
            else if (_mark(named, from)) revert DuplicateKey(p.key);

            moves[count++] = Move(p.key, id, from, p.index, position);
        }

        // A target must be empty or hold a record this call names. Since no two placements share
        // a target, a named occupant is always leaving.
        for (uint256 i = evictions.length; i < count; ++i) {
            uint256 index = moves[i].to;

            if (!_isMarked(named, index) && _load(_packedSlot(dir, stride, index)) != 0) {
                revert IndexTaken(index);
            }
        }

        assembly ("memory-safe") {
            mstore(moves, count)
        }
    }

    /// Moves each record's identity and data. Every source is read and cleared before any
    /// destination is written, so a record can move into a slot another is leaving. Clearing
    /// first also keeps a page's occupied-slot count from rising past where it started, so moves
    /// within a page don't pay MIP-8's 17,000 gas state-growth charge. Home flags are set and
    /// cleared alongside, when the space keeps them.
    function _relocate(uint256 dir, uint256 stride, Move[] memory moves, bool flags) private {
        uint256 words = stride - 1;
        uint256[] memory data = new uint256[](moves.length * words);

        for (uint256 i; i < moves.length; ++i) {
            Move memory m = moves[i];

            uint256 from = _dataSlot(dir, stride, m.id, m.from);
            if (m.from != AT_HOME) _store(from - 1, 0);
            if (flags && m.to == AT_HOME) _store(_packedFlag(m.id), 0);

            // Zero words are skipped: there is nothing to clear and nothing to copy.
            for (uint256 w; w < words; ++w) {
                uint256 value = _load(from + w);

                if (value != 0) {
                    data[i * words + w] = value;
                    _store(from + w, 0);
                }
            }
        }

        for (uint256 i; i < moves.length; ++i) {
            Move memory m = moves[i];

            uint256 to = _dataSlot(dir, stride, m.id, m.to);
            if (m.to != AT_HOME) _store(to - 1, m.id);
            if (flags && m.from == AT_HOME) _store(_packedFlag(m.id), 1);

            for (uint256 w; w < words; ++w) {
                uint256 value = data[i * words + w];
                if (value != 0) _store(to + w, value);
            }
        }
    }

    // ------------------------------------------------------------------------------------------
    // Layout
    // ------------------------------------------------------------------------------------------

    /// Identifies a record in packed storage and derives its home and fingerprint. Hashing the
    /// space in means the same key in two spaces never collides, and the result is never zero in
    /// practice, so zero can mark an empty packed slot.
    function _identity(Space s, bytes32 key) private pure returns (uint256 id) {
        assembly ("memory-safe") {
            mstore(0x00, s)
            mstore(0x20, key)
            id := keccak256(0x00, 0x40)
        }
    }

    function _directory(Space s) private pure returns (uint256 dir) {
        assembly ("memory-safe") {
            mstore(0x00, s)
            dir := and(keccak256(0x00, 0x20), not(127))
        }
    }

    /// Page-aligned, so a record of up to 128 words never straddles two pages.
    function _home(uint256 id) private pure returns (uint256) {
        return id & ~(PAGE_SIZE - 1);
    }

    /// Set while a record is packed, in spaces that keep home flags. It sits in the last slot of
    /// the home page, which data never reaches because records are at most 127 words wide.
    function _packedFlag(uint256 id) private pure returns (uint256) {
        return _home(id) + PAGE_SIZE - 1;
    }

    /// The first data word of a record at packed `index`, or at home.
    function _dataSlot(uint256 dir, uint256 stride, uint256 id, uint256 index)
        private
        pure
        returns (uint256)
    {
        return index == AT_HOME ? _home(id) : _packedSlot(dir, stride, index) + 1;
    }

    /// Records never straddle pages: each page holds floor(128 / stride) whole records and the
    /// remainder is left unused.
    ///
    /// Runs on every packed lookup. stride is 2..128 and index < 1024, so nothing can overflow
    /// or divide by zero, and skipping Solidity's checks here saves a few hundred gas per call.
    function _packedSlot(uint256 dir, uint256 stride, uint256 index)
        private
        pure
        returns (uint256 location)
    {
        assembly ("memory-safe") {
            let perPage := div(PAGE_SIZE, stride)
            let page := add(1, div(index, perPage))

            location := add(add(dir, shl(7, page)), mul(mod(index, perPage), stride))
        }
    }

    // ------------------------------------------------------------------------------------------
    // Directory
    // ------------------------------------------------------------------------------------------

    /// A record's packed index and directory position, or AT_HOME if it isn't packed.
    function _locate(uint256 dir, uint256 stride, uint256 id)
        private
        view
        returns (uint256 index, uint256 position)
    {
        bool found;
        (found, index, position) = LibDirectory.search(dir, id);

        if (!found || _load(_packedSlot(dir, stride, index)) != id) return (AT_HOME, 0);
    }

    /// Rewrites the index bits of records that moved between packed slots. Their fingerprints
    /// don't change, so the directory stays sorted.
    function _updateIndices(uint256 dir, Move[] memory moves) private {
        for (uint256 i; i < moves.length; ++i) {
            Move memory m = moves[i];
            if (m.from == AT_HOME || m.to == AT_HOME) continue;

            LibDirectory.setIndex(dir, m.position, m.to);
        }
    }

    /// Rebuilds the directory after records were packed or evicted: evicted records' entries
    /// are dropped and new ones merged in by fingerprint.
    function _rebuild(uint256 dir, Move[] memory moves, uint256 evicted, uint256 added) private {
        if (LibDirectory.length(dir) - evicted + added > MAX_PACKED) revert DirectoryFull();

        (uint256[4] memory removed, uint256[] memory insertions) = _changes(moves, added);

        (bool collided, uint256 move, uint256 lastMove) =
            LibDirectory.rebuild(dir, removed, evicted, insertions);

        if (collided) _revertCollision(moves, move, lastMove);
    }

    /// The directory positions of evicted records, and the entries of newly packed records.
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
    /// The other is ~0 if it was a kept entry. Only two insertions can be the same record.
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
