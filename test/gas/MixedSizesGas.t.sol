// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Entry, PagePack, PagedMap} from "pagepack/PagePack.sol";

/// Two-slot accounts, each with a one-slot approval, stored one of three ways by the contracts
/// below. A spend reads and writes both of an account's slots and its approval.
abstract contract AccountsAndApprovals {
    function account(bytes32 key) internal view virtual returns (Entry);

    function approval(bytes32 key) internal view virtual returns (Entry);

    function accountHint(bytes32 key) external view virtual returns (uint256);

    function approvalHint(bytes32 key) external view virtual returns (uint256);

    /// The keys an account and its approval are stored under, for building hints.
    function accountKeyOf(bytes32 key) public pure virtual returns (bytes32) {
        return key;
    }

    function approvalKeyOf(bytes32 key) public pure virtual returns (bytes32) {
        return approvalKey(key);
    }

    /// Packs account i at `accountAt[i]` and its approval at `approvalAt[i]`.
    function pack(
        bytes32[] calldata keys,
        uint256[] calldata accountAt,
        uint256[] calldata approvalAt
    ) external virtual;

    function _useHints(PagePack.Hint[] calldata hints) internal virtual;

    function seed(bytes32[] calldata keys) external {
        for (uint256 i; i < keys.length; ++i) {
            Entry a = account(keys[i]);
            a.write(0, 1_000);
            a.write(1, 1_000);
            approval(keys[i]).write(0, 1_000);
        }
    }

    function spend(bytes32[] calldata keys, PagePack.Hint[] calldata hints) external {
        _useHints(hints);

        for (uint256 i; i < keys.length; ++i) {
            Entry a = account(keys[i]);
            Entry p = approval(keys[i]);

            p.write(0, p.read(0) - 1);
            a.write(0, a.read(0) - 1);
            a.write(1, a.read(1) + 1);
        }
    }

    function balanceOf(bytes32 key) external view returns (uint256, uint256, uint256) {
        return (account(key).read(0), account(key).read(1), approval(key).read(0));
    }
}

/// An approval's key is its account's with the low bit flipped, so both fit one map.
function approvalKey(bytes32 key) pure returns (bytes32) {
    return key ^ bytes32(uint256(1));
}

/// The conventional baseline: a mapping of two-slot account structs and a mapping of approvals.
/// An account's two slots share a page, but every account and approval is on a page of its own.
contract Mappings is AccountsAndApprovals {
    struct Account {
        uint256 balance;
        uint256 received;
    }

    struct Approval {
        uint256 amount;
    }

    mapping(bytes32 key => Account) internal accounts;
    mapping(bytes32 key => Approval) internal approvals;

    function account(bytes32 key) internal view override returns (Entry e) {
        Account storage a = accounts[key];

        assembly ("memory-safe") {
            e := a.slot
        }
    }

    function approval(bytes32 key) internal view override returns (Entry e) {
        Approval storage a = approvals[key];

        assembly ("memory-safe") {
            e := a.slot
        }
    }

    function accountHint(bytes32) external pure override returns (uint256) {
        return 0;
    }

    function approvalHint(bytes32) external pure override returns (uint256) {
        return 0;
    }

    function pack(bytes32[] calldata, uint256[] calldata, uint256[] calldata) external override {}

    function _useHints(PagePack.Hint[] calldata) internal override {}
}

/// A map per size: accounts and approvals never share a page.
contract TwoMaps is AccountsAndApprovals {
    PagedMap internal immutable ACCOUNTS = PagePack.map("bench.accounts", 2);
    PagedMap internal immutable APPROVALS = PagePack.map("bench.approvals", 1);

    function account(bytes32 key) internal view override returns (Entry) {
        return ACCOUNTS.find(key);
    }

    function approval(bytes32 key) internal view override returns (Entry) {
        return APPROVALS.find(approvalKey(key));
    }

    function accountHint(bytes32 key) external view override returns (uint256) {
        return ACCOUNTS.hintOf(key);
    }

    function approvalHint(bytes32 key) external view override returns (uint256) {
        return APPROVALS.hintOf(approvalKey(key));
    }

    function pack(
        bytes32[] calldata keys,
        uint256[] calldata accountAt,
        uint256[] calldata approvalAt
    ) external override {
        PagePack.Placement[] memory accounts = new PagePack.Placement[](keys.length);
        PagePack.Placement[] memory approvals = new PagePack.Placement[](keys.length);

        for (uint256 i; i < keys.length; ++i) {
            accounts[i] = PagePack.Placement(keys[i], accountAt[i]);
            approvals[i] = PagePack.Placement(approvalKey(keys[i]), approvalAt[i]);
        }

        ACCOUNTS.rebalance(accounts);
        APPROVALS.rebalance(approvals);
    }

    /// Account hints first, then approval hints.
    function _useHints(PagePack.Hint[] calldata hints) internal override {
        ACCOUNTS.useHints(hints[:hints.length / 2]);
        APPROVALS.useHints(hints[hints.length / 2:]);
    }
}

/// One map pinned to the accounts' two slots, so each approval leaves a slot unused.
contract PinnedMap is AccountsAndApprovals {
    PagedMap internal immutable MAP = PagePack.map("bench.pinned", 2);

    function account(bytes32 key) internal view override returns (Entry) {
        return MAP.find(key);
    }

    function approval(bytes32 key) internal view override returns (Entry) {
        return MAP.find(approvalKey(key));
    }

    function accountHint(bytes32 key) external view override returns (uint256) {
        return MAP.hintOf(key);
    }

    function approvalHint(bytes32 key) external view override returns (uint256) {
        return MAP.hintOf(approvalKey(key));
    }

    function pack(
        bytes32[] calldata keys,
        uint256[] calldata accountAt,
        uint256[] calldata approvalAt
    ) external override {
        PagePack.Placement[] memory placements = new PagePack.Placement[](2 * keys.length);

        for (uint256 i; i < keys.length; ++i) {
            placements[2 * i] = PagePack.Placement(keys[i], accountAt[i]);
            placements[2 * i + 1] = PagePack.Placement(approvalKey(keys[i]), approvalAt[i]);
        }

        MAP.rebalance(placements);
    }

    function _useHints(PagePack.Hint[] calldata hints) internal override {
        MAP.useHints(hints);
    }
}

/// One map of two kinds, one-slot approvals and two-slot accounts. Each key holds its kind in
/// the top byte, over the first 31 bytes of the benchmark's key.
contract KindedMap is AccountsAndApprovals {
    uint256 internal constant APPROVAL = 0;
    uint256 internal constant ACCOUNT = 1;

    PagedMap internal immutable MAP =
        PagePack.mapOfKinds("bench.mixed").withKind(APPROVAL, 1).withKind(ACCOUNT, 2).build();

    function accountKeyOf(bytes32 key) public pure override returns (bytes32) {
        return PagePack.hashedKindKey(ACCOUNT, key);
    }

    function approvalKeyOf(bytes32 key) public pure override returns (bytes32) {
        return PagePack.hashedKindKey(APPROVAL, key);
    }

    function account(bytes32 key) internal view override returns (Entry) {
        return MAP.find(accountKeyOf(key));
    }

    function approval(bytes32 key) internal view override returns (Entry) {
        return MAP.find(approvalKeyOf(key));
    }

    function accountHint(bytes32 key) external view override returns (uint256) {
        return MAP.hintOf(accountKeyOf(key));
    }

    function approvalHint(bytes32 key) external view override returns (uint256) {
        return MAP.hintOf(approvalKeyOf(key));
    }

    function pack(
        bytes32[] calldata keys,
        uint256[] calldata accountAt,
        uint256[] calldata approvalAt
    ) external override {
        PagePack.Placement[] memory placements = new PagePack.Placement[](2 * keys.length);

        for (uint256 i; i < keys.length; ++i) {
            placements[2 * i] = PagePack.Placement(accountKeyOf(keys[i]), accountAt[i]);
            placements[2 * i + 1] = PagePack.Placement(approvalKeyOf(keys[i]), approvalAt[i]);
        }

        MAP.rebalance(placements);
    }

    function _useHints(PagePack.Hint[] calldata hints) internal override {
        MAP.useHints(hints);
    }
}

/// Measures spending from N accounts under their approvals in one transaction, with every entry
/// packed and hinted. Each test is its own transaction, so every page starts cold.
///
/// - Mappings: Solidity mappings, the baseline. Every account and approval is on its own page.
/// - Two maps: accounts and approvals each fill pages of their own.
/// - One map, width 2: approvals pinned to the accounts' width, 42 entries per page.
/// - One map of both sizes: a map of two kinds with 50 tags per page, so 25 accounts and their
///   25 approvals share a page.
contract MixedSizesGasTest is Test {
    Mappings internal mappings;
    TwoMaps internal twoMaps;
    PinnedMap internal pinned;
    KindedMap internal mixed;

    function setUp() public {
        mappings = new Mappings();
        twoMaps = new TwoMaps();
        pinned = new PinnedMap();
        mixed = new KindedMap();

        bytes32[] memory keys = _keys(25);
        uint256[] memory separate = new uint256[](25);
        uint256[] memory accountAt = new uint256[](25);
        uint256[] memory approvalAt = new uint256[](25);

        for (uint256 i; i < 25; ++i) {
            separate[i] = i;
            accountAt[i] = 2 * i;
            approvalAt[i] = 2 * i + 1;
        }

        mappings.seed(keys);
        twoMaps.seed(keys);
        pinned.seed(keys);
        mixed.seed(keys);

        twoMaps.pack(keys, separate, separate);
        pinned.pack(keys, accountAt, approvalAt);
        mixed.pack(keys, accountAt, approvalAt);
    }

    function test_gas_spend_10() public {
        _spend(mappings, "mixed-mappings", 10);
        _spend(twoMaps, "mixed-two-maps", 10);
        _spend(pinned, "mixed-pinned", 10);
        _spend(mixed, "mixed-sizes", 10);
    }

    function test_gas_spend_25() public {
        _spend(mappings, "mixed-mappings", 25);
        _spend(twoMaps, "mixed-two-maps", 25);
        _spend(pinned, "mixed-pinned", 25);
        _spend(mixed, "mixed-sizes", 25);
    }

    function _spend(AccountsAndApprovals target, string memory group, uint256 count) internal {
        bytes32[] memory keys = _keys(count);

        // Mappings take no hints.
        PagePack.Hint[] memory hints = new PagePack.Hint[](target == mappings ? 0 : 2 * count);

        for (uint256 i; i < hints.length / 2; ++i) {
            hints[i] = PagePack.Hint(target.accountKeyOf(keys[i]), target.accountHint(keys[i]));
            hints[count + i] =
                PagePack.Hint(target.approvalKeyOf(keys[i]), target.approvalHint(keys[i]));
        }

        // Reading hints above warmed the pages. Measure in a fresh transaction.
        vm.cool(address(target));

        target.spend(keys, hints);
        vm.snapshotGasLastCall(group, string.concat(vm.toString(count), " accounts"));

        (uint256 balance, uint256 received, uint256 allowance) = target.balanceOf(keys[0]);
        assertEq(balance, 999);
        assertEq(received, 1_001);
        assertEq(allowance, 999);
    }

    function _keys(uint256 count) internal pure returns (bytes32[] memory keys) {
        keys = new bytes32[](count);

        for (uint256 i; i < count; ++i) {
            keys[i] = keccak256(abi.encode("mixed", i)) & ~bytes32(uint256(1));
        }
    }
}
