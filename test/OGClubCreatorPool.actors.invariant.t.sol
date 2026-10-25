// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OGClubCreatorPool} from "../src/OGClubCreatorPool.sol";
import {MockOG} from "./support/MockOG.sol";
import {Merkle} from "./support/Merkle.sol";

/// @notice Drives the pool with several actors and, unlike a handler that only takes valid steps, also
///         attempts what must fail: claims out of their window, forged and replayed proofs, owner-only
///         calls from strangers, owner attempts on payouts and on opened months, early sweeps. Every
///         attempt is checked against an independent model of what the pool should accept; any
///         disagreement is counted in `unexpected` with the step that caused it.
contract ActorsHandler is Test {
    uint256 internal constant GAMES = 5;
    uint256 internal constant ACTORS = 3;

    MockOG public og;
    OGClubCreatorPool public pool;
    address public owner;
    address public funder = makeAddr("actors-funder");
    address[ACTORS] public relayers;

    bytes32[GAMES] public gameIds;
    address[GAMES] public payoutOf;
    address[] public allPayouts;

    uint256[] public proposedMonths;
    mapping(uint256 => bool) internal seen;
    mapping(uint256 => bytes32[]) internal leavesOf;
    mapping(uint256 => uint256[]) internal amountsOf;
    mapping(uint256 => uint256) public paidOf;
    uint256 public nextMonth = 202_601;
    uint256 internal salt;

    uint256 public ghostFunded;
    uint256 public ghostPaid;
    uint256 public unexpected;
    string public lastUnexpected;

    uint256 public okClaims;
    uint256 public okSweeps;
    uint256 public okCancels;
    uint256 public okProposals;

    constructor(MockOG og_, OGClubCreatorPool pool_, address owner_) {
        og = og_;
        pool = pool_;
        owner = owner_;
        for (uint256 i; i < ACTORS; ++i) {
            relayers[i] = makeAddr(string.concat("actors-relayer", vm.toString(i)));
        }
        for (uint256 i; i < GAMES; ++i) {
            gameIds[i] = pool.gameId(string.concat("kit-", vm.toString(i)));
            payoutOf[i] = makeAddr(string.concat("actors-dev", vm.toString(i)));
            allPayouts.push(payoutOf[i]);
            vm.prank(owner);
            pool.listGame(gameIds[i], payoutOf[i]);
        }
        og.mint(funder, type(uint128).max);
    }

    function monthsCount() external view returns (uint256) {
        return proposedMonths.length;
    }

    function payoutsCount() external view returns (uint256) {
        return allPayouts.length;
    }

    function _flag(string memory what) internal {
        ++unexpected;
        lastUnexpected = what;
    }

    function _pick(uint256 idx) internal view returns (uint256 month, bool ok) {
        if (proposedMonths.length == 0) return (0, false);
        return (proposedMonths[bound(idx, 0, proposedMonths.length - 1)], true);
    }

    function _m(uint256 month)
        internal
        view
        returns (uint256 total, uint256 remaining, uint256 opensAt, bool cancelled, bool swept)
    {
        uint64 o;
        (, total, remaining, o, cancelled, swept) = pool.months(month);
        opensAt = o;
    }

    // ───────────────────────────────────────────────────────────────────────── money in ──

    function fund(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000 ether);
        vm.startPrank(funder);
        og.approve(address(pool), amount);
        pool.fund(amount);
        vm.stopPrank();
        ghostFunded += amount;
    }

    function transferIn(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000 ether);
        vm.prank(funder);
        og.transfer(address(pool), amount);
        ghostFunded += amount;
    }

    // ─────────────────────────────────────────────────────────────────────── owner steps ──

    function propose(uint256 seed, uint8 countRaw, uint256 total, bool oversubscribe) external {
        uint256 free = pool.free();
        if (free == 0) return;
        uint256 count = bound(countRaw, 1, GAMES);
        total = bound(total, 1, free);
        uint256 month = nextMonth;
        bytes32[] memory leaves = new bytes32[](count);
        uint256[] memory amounts = new uint256[](count);
        // Oversubscribed lists add up to more than `total`; the cap on chain must hold anyway.
        uint256 cap = oversubscribe ? total : total / count;
        if (cap == 0) cap = 1;
        for (uint256 i; i < count; ++i) {
            amounts[i] = bound(uint256(keccak256(abi.encode(seed, i))), 1, cap);
            leaves[i] = pool.leaf(month, gameIds[i], amounts[i]);
        }
        bytes32 root = Merkle.root(leaves);
        vm.prank(owner);
        try pool.proposeMonth(month, root, total) {
            ++okProposals;
        } catch {
            _flag("valid proposal refused");
            return;
        }
        if (!seen[month]) {
            seen[month] = true;
            proposedMonths.push(month);
        }
        delete leavesOf[month];
        delete amountsOf[month];
        for (uint256 i; i < count; ++i) {
            leavesOf[month].push(leaves[i]);
            amountsOf[month].push(amounts[i]);
        }
        paidOf[month] = 0;
        nextMonth = month % 100 == 12 ? (month / 100 + 1) * 100 + 1 : month + 1;
    }

    /// @dev Proposals the pool must refuse: an old month, too much, zero root, zero total, bad id.
    function proposeBad(uint8 kind, uint256 amount) external {
        uint256 free = pool.free();
        uint256 last = pool.lastMonth();
        uint256 month = nextMonth;
        bytes32 root = keccak256(abi.encode(kind, amount));
        uint256 total = bound(amount, 1, 1_000_000 ether);
        kind = uint8(bound(kind, 0, 4));
        if (kind == 0) {
            if (last == 0) return;
            (,,, bool cancelled,) = _m(last);
            if (cancelled) return; // re-proposing a cancelled last month is allowed
            month = last;
            if (total > free) total = free == 0 ? 1 : free;
        } else if (kind == 1) {
            total = free + 1 + (amount % 1000);
        } else if (kind == 2) {
            root = bytes32(0);
        } else if (kind == 3) {
            total = 0;
        } else {
            month = month / 100 * 100 + 13;
        }
        vm.prank(owner);
        try pool.proposeMonth(month, root, total) {
            _flag("bad proposal accepted");
        } catch {}
    }

    function cancel(uint256 idx) external {
        (uint256 month, bool ok) = _pick(idx);
        if (!ok) return;
        (, uint256 remaining, uint256 opensAt, bool cancelled,) = _m(month);
        bool shouldWork = !cancelled && block.timestamp < opensAt;
        uint256 reservedBefore = pool.reserved();
        vm.prank(owner);
        try pool.cancelMonth(month) {
            if (!shouldWork) _flag("cancel of opened or cancelled month accepted");
            if (pool.reserved() != reservedBefore - remaining) _flag("cancel released wrong amount");
            ++okCancels;
            if (month == pool.lastMonth()) nextMonth = month;
        } catch {
            if (shouldWork) _flag("cancel of pending month refused");
        }
    }

    /// @dev Strangers, relayers and game wallets trying owner-only calls.
    function strangerOwnerCall(uint8 who, uint8 what, uint256 idx) external {
        address caller = who % 2 == 0 ? relayers[who % ACTORS] : payoutOf[who % GAMES];
        uint256 g = bound(idx, 0, GAMES - 1);
        (uint256 month,) = _pick(idx);
        vm.prank(caller);
        bool success;
        uint8 w = what % 5;
        if (w == 0) {
            try pool.listGame(keccak256(abi.encode("new", idx)), caller) {
                success = true;
            } catch {}
        } else if (w == 1) {
            try pool.delistGame(gameIds[g]) {
                success = true;
            } catch {}
        } else if (w == 2) {
            try pool.relistGame(gameIds[g]) {
                success = true;
            } catch {}
        } else if (w == 3) {
            try pool.proposeMonth(nextMonth, keccak256("r"), 1) {
                success = true;
            } catch {}
        } else {
            try pool.cancelMonth(month) {
                success = true;
            } catch {}
        }
        if (success) _flag("owner-only call accepted from non-owner");
    }

    /// @dev The owner trying to move a game's payout (to itself or anyone).
    function ownerChangesPayout(uint8 gameRaw, bool toSelf) external {
        uint256 g = bound(gameRaw, 0, GAMES - 1);
        address to = toSelf ? owner : makeAddr(string.concat("owner-pick", vm.toString(gameRaw)));
        vm.prank(owner);
        try pool.changePayout(gameIds[g], to) {
            _flag("owner changed a payout");
        } catch {}
    }

    function toggleListing(uint8 gameRaw) external {
        uint256 g = bound(gameRaw, 0, GAMES - 1);
        (, bool listed) = pool.games(gameIds[g]);
        vm.prank(owner);
        if (listed) pool.delistGame(gameIds[g]);
        else pool.relistGame(gameIds[g]);
    }

    // ──────────────────────────────────────────────────────────────────── anyone steps ──

    /// @dev A claim with a genuine proof, pushed by anyone (including the owner), at any time.
    function claim(uint256 idx, uint8 gameRaw, uint8 who) external {
        (uint256 month, bool ok) = _pick(idx);
        if (!ok) return;
        _claim(month, bound(gameRaw, 0, leavesOf[month].length - 1), who);
    }

    /// @dev Looks for a leaf that is claimable right now and claims it, so sequences reach payouts.
    function claimOpen(uint256 idx, uint8 who) external {
        uint256 n = proposedMonths.length;
        for (uint256 k; k < n; ++k) {
            uint256 month = proposedMonths[(idx + k) % n];
            (, uint256 remaining, uint256 opensAt, bool cancelled,) = _m(month);
            if (cancelled || block.timestamp < opensAt || block.timestamp >= opensAt + 90 days) continue;
            uint256 count = leavesOf[month].length;
            for (uint256 g; g < count; ++g) {
                if (!pool.claimed(month, gameIds[g]) && amountsOf[month][g] <= remaining) {
                    _claim(month, g, who);
                    return;
                }
            }
        }
    }

    function _claim(uint256 month, uint256 g, uint8 who) internal {
        bytes32[] storage leaves = leavesOf[month];
        uint256 amount = amountsOf[month][g];
        (, uint256 remaining, uint256 opensAt, bool cancelled,) = _m(month);
        bool shouldWork = !cancelled && block.timestamp >= opensAt && block.timestamp < opensAt + 90 days
            && !pool.claimed(month, gameIds[g]) && amount <= remaining;

        address payout = payoutOf[g];
        uint256 before = og.balanceOf(payout);
        address caller = who % 4 == 3 ? owner : relayers[who % ACTORS];
        bytes32[] memory proof = Merkle.proof(leaves, g);
        vm.prank(caller);
        try pool.claim(month, gameIds[g], amount, proof) {
            if (!shouldWork) _flag("claim accepted outside the rules");
            if (og.balanceOf(payout) != before + amount) _flag("claim did not pay the current payout wallet");
            ghostPaid += amount;
            paidOf[month] += amount;
            ++okClaims;
        } catch {
            if (shouldWork) _flag("valid claim refused");
        }
    }

    /// @dev Claims that must never pay: wrong amount, wrong game, another month's proof.
    function forgedClaim(uint256 idx, uint8 gameRaw, uint8 kind, uint256 delta) external {
        (uint256 month, bool ok) = _pick(idx);
        if (!ok) return;
        bytes32[] storage leaves = leavesOf[month];
        uint256 g = bound(gameRaw, 0, leaves.length - 1);
        uint256 amount = amountsOf[month][g];
        bytes32 game = gameIds[g];
        uint256 claimMonth = month;
        kind = uint8(bound(kind, 0, 2));
        if (kind == 0) {
            amount += bound(delta, 1, 1_000 ether);
        } else if (kind == 1) {
            game = gameIds[(g + 1 + bound(delta, 0, GAMES - 2)) % GAMES];
        } else {
            (uint256 other, bool ok2) = _pick(delta);
            if (!ok2 || other == month) return;
            claimMonth = other;
        }
        bytes32[] memory proof = Merkle.proof(leaves, g);
        vm.prank(relayers[0]);
        try pool.claim(claimMonth, game, amount, proof) {
            _flag("forged claim paid");
        } catch {}
    }

    function sweep(uint256 idx, uint8 who) external {
        (uint256 month, bool ok) = _pick(idx);
        if (!ok) return;
        _sweep(month, who);
    }

    /// @dev Looks for a month whose window has closed and sweeps it.
    function sweepClosed(uint256 idx, uint8 who) external {
        uint256 n = proposedMonths.length;
        for (uint256 k; k < n; ++k) {
            uint256 month = proposedMonths[(idx + k) % n];
            (,, uint256 opensAt, bool cancelled, bool swept) = _m(month);
            if (!cancelled && !swept && block.timestamp >= opensAt + 90 days) {
                _sweep(month, who);
                return;
            }
        }
    }

    function _sweep(uint256 month, uint8 who) internal {
        (, uint256 remaining, uint256 opensAt, bool cancelled, bool swept) = _m(month);
        bool shouldWork = !cancelled && !swept && block.timestamp >= opensAt + 90 days;
        uint256 reservedBefore = pool.reserved();
        uint256 balanceBefore = og.balanceOf(address(pool));
        vm.prank(who % 2 == 0 ? owner : relayers[who % ACTORS]);
        try pool.sweep(month) {
            if (!shouldWork) _flag("sweep accepted outside the rules");
            if (pool.reserved() != reservedBefore - remaining) _flag("sweep released wrong amount");
            if (og.balanceOf(address(pool)) != balanceBefore) _flag("sweep moved tokens");
            ++okSweeps;
        } catch {
            if (shouldWork) _flag("valid sweep refused");
        }
    }

    function changePayout(uint8 gameRaw, uint256 s) external {
        uint256 g = bound(gameRaw, 0, GAMES - 1);
        address to = makeAddr(string.concat("actors-moved", vm.toString(++salt), "-", vm.toString(s % 1000)));
        vm.prank(payoutOf[g]);
        pool.changePayout(gameIds[g], to);
        payoutOf[g] = to;
        allPayouts.push(to);
    }

    /// @dev Mostly short steps so sequences spend time inside claim windows; one in four jumps far
    ///      enough to close windows and make sweeps possible.
    function warp(uint256 secs, uint8 kind) external {
        skip(kind % 4 == 0 ? bound(secs, 45 days, 100 days) : bound(secs, 1, 4 days));
    }
}

contract OGClubCreatorPoolActorsInvariantTest is Test {
    MockOG internal og;
    OGClubCreatorPool internal pool;
    ActorsHandler internal handler;
    address internal owner = makeAddr("actors-owner");

    function setUp() public {
        vm.warp(1_790_000_007);
        og = new MockOG();
        pool = new OGClubCreatorPool(IERC20(address(og)), owner);
        handler = new ActorsHandler(og, pool, owner);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 120
    function invariant_poolAgreesWithModelOnEveryAttempt() public view {
        assertEq(handler.unexpected(), 0, handler.lastUnexpected());
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 120
    function invariant_balanceCoversReservedAndConserves() public view {
        uint256 balance = og.balanceOf(address(pool));
        assertGe(balance, pool.reserved());
        assertEq(balance, handler.ghostFunded() - handler.ghostPaid());
        assertEq(pool.free(), balance - pool.reserved());
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 120
    function invariant_reservedIsSumOfOpenMonthsRemaining_andMonthsNeverOverpay() public view {
        uint256 sum;
        uint256 n = handler.monthsCount();
        for (uint256 i; i < n; ++i) {
            uint256 month = handler.proposedMonths(i);
            (, uint256 total, uint256 remaining,, bool cancelled, bool swept) = pool.months(month);
            uint256 paid = handler.paidOf(month);
            assertLe(paid, total, "month paid more than its total");
            if (cancelled || swept) assertEq(remaining, 0, "closed-out month still holds a reservation");
            else assertEq(remaining, total - paid, "remaining != total - paid");
            assertTrue(pool.isValidMonth(month));
            assertLe(month, pool.lastMonth());
            sum += remaining;
        }
        assertEq(pool.reserved(), sum);
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 120
    function invariant_onlyPayoutWalletsEverReceive() public view {
        assertEq(og.balanceOf(owner), 0, "owner gained $OG");
        for (uint256 i; i < 3; ++i) {
            assertEq(og.balanceOf(handler.relayers(i)), 0, "a caller gained $OG");
        }
        uint256 sum;
        uint256 n = handler.payoutsCount();
        for (uint256 i; i < n; ++i) {
            sum += og.balanceOf(handler.allPayouts(i));
        }
        assertEq(sum, handler.ghostPaid());
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 120
    function invariant_ownerAndTokenFixed() public view {
        assertEq(pool.owner(), owner);
        assertEq(address(pool.token()), address(og));
    }
}
