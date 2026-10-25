// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OGClubCreatorPool} from "../src/OGClubCreatorPool.sol";
import {MockOG} from "./support/MockOG.sol";
import {Merkle} from "./support/Merkle.sol";

/// @notice ERC-20 whose transfers call `onTokenReceived` on a contract recipient (ERC-777 / ERC-1363 shape).
contract HookToken is ERC20 {
    constructor() ERC20("Hook OG", "HOG") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && to.code.length > 0) {
            IReceiveHook(to).onTokenReceived(from, value);
        }
    }
}

interface IReceiveHook {
    function onTokenReceived(address from, uint256 value) external;
}

/// @notice A game's payout wallet that tries to re-enter the pool while being paid.
contract ReenteringPayout is IReceiveHook {
    enum Mode {
        None,
        ClaimOther,
        Fund,
        Sweep,
        ClaimOtherSwallow
    }

    OGClubCreatorPool public immutable pool;
    Mode public mode;
    uint256 public month;
    bytes32 public otherGame;
    uint256 public otherAmount;
    bytes32[] internal otherProof;
    bool public reentryFailed;
    bytes public reentryError;

    constructor(OGClubCreatorPool pool_) {
        pool = pool_;
    }

    function arm(Mode mode_, uint256 month_, bytes32 game, uint256 amount, bytes32[] memory proof) external {
        mode = mode_;
        month = month_;
        otherGame = game;
        otherAmount = amount;
        otherProof = proof;
    }

    function onTokenReceived(address, uint256) external {
        if (msg.sender != address(pool.token())) return;
        Mode m = mode;
        mode = Mode.None;
        if (m == Mode.ClaimOther) {
            pool.claim(month, otherGame, otherAmount, otherProof);
        } else if (m == Mode.Fund) {
            pool.fund(1);
        } else if (m == Mode.Sweep) {
            pool.sweep(month);
        } else if (m == Mode.ClaimOtherSwallow) {
            try pool.claim(month, otherGame, otherAmount, otherProof) {}
            catch (bytes memory err) {
                reentryFailed = true;
                reentryError = err;
            }
        }
    }
}

/// @notice ERC-20 whose `transfer` / `transferFrom` return false instead of reverting, and move nothing.
contract ReturnsFalseToken is ERC20 {
    bool public broken;

    constructor() ERC20("False OG", "FOG") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function breakIt() external {
        broken = true;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (broken) return false;
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (broken) return false;
        return super.transferFrom(from, to, value);
    }
}

/// @notice USDT-shaped token: `transfer` and `transferFrom` return nothing.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice Edges the main suite leaves open: exact window boundaries, overwrite semantics of a cancelled
///         month, cross-month and cross-game proof replay, re-entrancy through a hook token, tokens that
///         return false or nothing, ownership handover, large trees and several months at once.
contract OGClubCreatorPoolAdversarialTest is Test {
    uint256 internal constant START = 1_800_000_123; // deliberately not a round number
    uint256 internal constant M1 = 202_611;
    uint256 internal constant M2 = 202_612;
    uint256 internal constant M3 = 202_701;

    MockOG internal og;
    OGClubCreatorPool internal pool;

    address internal owner = makeAddr("owner");
    address internal funder = makeAddr("funder");
    address internal relayer = makeAddr("relayer");
    address internal dev1 = makeAddr("dev1");
    address internal dev2 = makeAddr("dev2");
    address internal dev3 = makeAddr("dev3");

    bytes32 internal G1;
    bytes32 internal G2;
    bytes32 internal G3;

    function setUp() public {
        vm.warp(START);
        og = new MockOG();
        pool = new OGClubCreatorPool(IERC20(address(og)), owner);
        G1 = pool.gameId("coin-dash");
        G2 = pool.gameId("rocket-run");
        G3 = pool.gameId("puzzle-pit");
        vm.startPrank(owner);
        pool.listGame(G1, dev1);
        pool.listGame(G2, dev2);
        pool.listGame(G3, dev3);
        vm.stopPrank();
        og.mint(funder, 10_000_000 ether);
    }

    // ───────────────────────────────────────────────────────────────────────────── helpers ──

    function _fund(uint256 amount) internal {
        vm.startPrank(funder);
        og.approve(address(pool), amount);
        pool.fund(amount);
        vm.stopPrank();
    }

    /// @dev Three-game month: G1 100, G2 200, G3 300.
    function _leaves3(uint256 month) internal view returns (bytes32[] memory l) {
        l = new bytes32[](3);
        l[0] = pool.leaf(month, G1, 100 ether);
        l[1] = pool.leaf(month, G2, 200 ether);
        l[2] = pool.leaf(month, G3, 300 ether);
    }

    function _propose3(uint256 month) internal returns (bytes32[] memory l) {
        l = _leaves3(month);
        if (pool.free() < 600 ether) _fund(600 ether - pool.free());
        vm.prank(owner);
        pool.proposeMonth(month, Merkle.root(l), 600 ether);
    }

    function _month(uint256 month)
        internal
        view
        returns (uint256 total, uint256 remaining, uint64 opensAt, bool cancelled, bool swept)
    {
        (, total, remaining, opensAt, cancelled, swept) = pool.months(month);
    }

    function _opensAt(uint256 month) internal view returns (uint256 t) {
        (,, t,,) = _month(month);
    }

    function _status(uint256 month) internal view returns (uint8) {
        return uint8(pool.status(month));
    }

    // ───────────────────────────────────────────────────────────────── window boundaries ──

    function test_claimWindow_exactBoundaries() public {
        bytes32[] memory l = _propose3(M1);
        uint256 opensAt = _opensAt(M1);
        assertEq(opensAt, START + 3 days);
        uint256 closesAt = opensAt + 90 days;

        vm.warp(opensAt - 1);
        assertEq(_status(M1), uint8(OGClubCreatorPool.MonthStatus.Pending));
        assertFalse(pool.isOpen(M1));
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.ClaimNotOpen.selector, M1, uint64(opensAt)));
        pool.claim(M1, G1, 100 ether, Merkle.proof(l, 0));

        vm.warp(opensAt);
        assertEq(_status(M1), uint8(OGClubCreatorPool.MonthStatus.Open));
        assertTrue(pool.isOpen(M1));
        pool.claim(M1, G1, 100 ether, Merkle.proof(l, 0));
        assertEq(og.balanceOf(dev1), 100 ether);

        vm.warp(closesAt - 1);
        assertTrue(pool.isOpen(M1));
        pool.claim(M1, G2, 200 ether, Merkle.proof(l, 1));
        assertEq(og.balanceOf(dev2), 200 ether);

        vm.warp(closesAt);
        assertFalse(pool.isOpen(M1));
        assertEq(_status(M1), uint8(OGClubCreatorPool.MonthStatus.Closed));
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.ClaimClosed.selector, M1, closesAt));
        pool.claim(M1, G3, 300 ether, Merkle.proof(l, 2));
    }

    function test_cancel_exactBoundary() public {
        _propose3(M1);
        uint256 opensAt = _opensAt(M1);
        vm.warp(opensAt);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.MonthAlreadyOpen.selector, M1, uint64(opensAt)));
        pool.cancelMonth(M1);

        // One second earlier it was still cancellable.
        vm.warp(opensAt - 1);
        vm.prank(owner);
        pool.cancelMonth(M1);
        assertEq(pool.reserved(), 0);
        assertEq(_status(M1), uint8(OGClubCreatorPool.MonthStatus.Cancelled));
    }

    function test_sweep_exactBoundaryOnceAndNotWhilePendingOrOpen() public {
        bytes32[] memory l = _propose3(M1);
        uint256 closesAt = _opensAt(M1) + 90 days;

        // Pending: sweep refused.
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.ClaimWindowStillOpen.selector, M1, closesAt));
        pool.sweep(M1);

        vm.warp(closesAt - 1);
        pool.claim(M1, G3, 300 ether, Merkle.proof(l, 2));
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.ClaimWindowStillOpen.selector, M1, closesAt));
        pool.sweep(M1);

        vm.warp(closesAt);
        vm.prank(relayer);
        pool.sweep(M1);
        assertEq(pool.reserved(), 0);
        assertEq(pool.free(), 300 ether);
        assertEq(og.balanceOf(relayer), 0);
        assertEq(og.balanceOf(owner), 0);
        assertEq(_status(M1), uint8(OGClubCreatorPool.MonthStatus.Swept));

        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.NothingToSweep.selector, M1));
        pool.sweep(M1);

        // A swept month stays closed to claims and can never be cancelled.
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.ClaimClosed.selector, M1, closesAt));
        pool.claim(M1, G1, 100 ether, Merkle.proof(l, 0));
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(OGClubCreatorPool.MonthAlreadyOpen.selector, M1, uint64(closesAt - 90 days))
        );
        pool.cancelMonth(M1);
    }

    function test_cancelledMonth_cannotBeCancelledAgainOrSwept() public {
        _propose3(M1);
        vm.prank(owner);
        pool.cancelMonth(M1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.MonthWasCancelled.selector, M1));
        pool.cancelMonth(M1);

        skip(200 days);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.MonthWasCancelled.selector, M1));
        pool.sweep(M1);
        assertEq(pool.free(), 600 ether);
    }

    // ───────────────────────────────────────────────────────────── cancel and overwrite ──

    function test_overwrite_oldRootDeadNewRootLive() public {
        bytes32[] memory oldLeaves = _propose3(M1);
        vm.prank(owner);
        pool.cancelMonth(M1);

        // Re-propose the same id with a different list: only G2, 50.
        bytes32[] memory newLeaves = new bytes32[](2);
        newLeaves[0] = pool.leaf(M1, G2, 50 ether);
        newLeaves[1] = pool.leaf(M1, G3, 25 ether);
        skip(1 days);
        vm.prank(owner);
        pool.proposeMonth(M1, Merkle.root(newLeaves), 75 ether);
        (uint256 total, uint256 remaining, uint64 opensAt, bool cancelled, bool swept) = _month(M1);
        assertEq(total, 75 ether);
        assertEq(remaining, 75 ether);
        assertEq(opensAt, START + 1 days + 3 days, "a re-proposed month restarts its 3-day review");
        assertFalse(cancelled);
        assertFalse(swept);
        assertEq(pool.reserved(), 75 ether);
        assertEq(pool.free(), 525 ether);

        vm.warp(opensAt);
        vm.expectRevert(OGClubCreatorPool.InvalidProof.selector);
        pool.claim(M1, G1, 100 ether, Merkle.proof(oldLeaves, 0));
        vm.expectRevert(OGClubCreatorPool.InvalidProof.selector);
        pool.claim(M1, G2, 200 ether, Merkle.proof(oldLeaves, 1));

        pool.claim(M1, G2, 50 ether, Merkle.proof(newLeaves, 0));
        pool.claim(M1, G3, 25 ether, Merkle.proof(newLeaves, 1));
        assertEq(og.balanceOf(dev2), 50 ether);
        assertEq(og.balanceOf(dev3), 25 ether);
        assertEq(pool.reserved(), 0);
    }

    function test_overwrite_canReserveMoreThanTheCancelledVersion() public {
        _propose3(M1);
        _fund(400 ether);
        vm.prank(owner);
        pool.cancelMonth(M1);
        bytes32 root = pool.leaf(M1, G1, 1000 ether);
        vm.prank(owner);
        pool.proposeMonth(M1, root, 1000 ether);
        assertEq(pool.reserved(), 1000 ether);
        assertEq(pool.free(), 0);
    }

    function test_proposeSameMonthTwiceWithoutCancelReverts() public {
        _propose3(M1);
        _fund(600 ether);
        bytes32 root = Merkle.root(_leaves3(M1));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.MonthNotAfterLast.selector, M1, M1));
        pool.proposeMonth(M1, root, 600 ether);
        // Also after it opened, closed and was swept: a month id is never reused.
        skip(93 days);
        pool.sweep(M1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.MonthNotAfterLast.selector, M1, M1));
        pool.proposeMonth(M1, root, 600 ether);
    }

    function test_cancelledOlderMonthCannotComeBackOnceANewerOneExists() public {
        _propose3(M1);
        _propose3(M2);
        vm.prank(owner);
        pool.cancelMonth(M1);
        bytes32 root = Merkle.root(_leaves3(M1));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.MonthNotAfterLast.selector, M1, M2));
        pool.proposeMonth(M1, root, 600 ether);
        assertEq(pool.reserved(), 600 ether);
    }

    function test_yearRollover() public {
        _propose3(M2); // 2026-12
        _propose3(M3); // 2027-01
        assertEq(pool.lastMonth(), M3);
        _fund(1 ether);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.InvalidMonth.selector, 202_613));
        pool.proposeMonth(202_613, bytes32(uint256(1)), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.InvalidMonth.selector, 202_700));
        pool.proposeMonth(202_700, bytes32(uint256(1)), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.InvalidMonth.selector, 202_512));
        pool.proposeMonth(202_512, bytes32(uint256(1)), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.InvalidMonth.selector, 0));
        pool.proposeMonth(0, bytes32(uint256(1)), 1 ether);
        vm.stopPrank();
    }

    function test_firstValidMonthIsJanuary2026() public {
        assertTrue(pool.isValidMonth(202_601));
        assertFalse(pool.isValidMonth(202_600));
        assertFalse(pool.isValidMonth(202_512));
        _fund(1 ether);
        vm.prank(owner);
        pool.proposeMonth(202_601, bytes32(uint256(1)), 1 ether);
        assertEq(pool.lastMonth(), 202_601);
    }

    // ──────────────────────────────────────────────────────────────────────── replay ──

    function test_proofForOneMonthDoesNotWorkInAnother_evenWithTheSameRoot() public {
        bytes32[] memory l1 = _propose3(M1);
        // The owner (by mistake) reuses M1's root for M2.
        _fund(600 ether);
        vm.prank(owner);
        pool.proposeMonth(M2, Merkle.root(l1), 600 ether);
        skip(3 days);

        pool.claim(M1, G1, 100 ether, Merkle.proof(l1, 0));
        vm.expectRevert(OGClubCreatorPool.InvalidProof.selector);
        pool.claim(M2, G1, 100 ether, Merkle.proof(l1, 0));
        assertEq(og.balanceOf(dev1), 100 ether);
    }

    function test_proofCannotBeRedirectedToAnotherGameOrAmount() public {
        bytes32[] memory l = _propose3(M1);
        skip(3 days);
        bytes32[] memory p = Merkle.proof(l, 0);

        vm.expectRevert(OGClubCreatorPool.InvalidProof.selector);
        pool.claim(M1, G2, 100 ether, p);
        vm.expectRevert(OGClubCreatorPool.InvalidProof.selector);
        pool.claim(M1, G1, 100 ether + 1, p);
        vm.expectRevert(OGClubCreatorPool.InvalidProof.selector);
        pool.claim(M1, G1, 100 ether - 1, p);
        vm.expectRevert(OGClubCreatorPool.InvalidProof.selector);
        pool.claim(M1, G1, 100 ether, new bytes32[](0));

        // A proof with a junk element appended is refused too.
        bytes32[] memory longer = new bytes32[](p.length + 1);
        for (uint256 i; i < p.length; ++i) {
            longer[i] = p[i];
        }
        longer[p.length] = keccak256("junk");
        vm.expectRevert(OGClubCreatorPool.InvalidProof.selector);
        pool.claim(M1, G1, 100 ether, longer);

        assertEq(_month3Remaining(), 600 ether);
    }

    function _month3Remaining() internal view returns (uint256 r) {
        (, r,,,) = _month(M1);
    }

    function test_zeroAmountLeafIsRefusedEvenIfInTheTree() public {
        bytes32[] memory l = new bytes32[](2);
        l[0] = pool.leaf(M1, G1, 0);
        l[1] = pool.leaf(M1, G2, 10 ether);
        _fund(10 ether);
        vm.prank(owner);
        pool.proposeMonth(M1, Merkle.root(l), 10 ether);
        skip(3 days);
        vm.expectRevert(OGClubCreatorPool.ZeroAmount.selector);
        pool.claim(M1, G1, 0, Merkle.proof(l, 0));
        assertFalse(pool.claimed(M1, G1));
    }

    function test_leafForNeverListedGameIsUnclaimableUntilListed() public {
        bytes32 ghost = pool.gameId("not-yet-listed");
        bytes32[] memory l = new bytes32[](2);
        l[0] = pool.leaf(M1, ghost, 10 ether);
        l[1] = pool.leaf(M1, G1, 10 ether);
        _fund(20 ether);
        vm.prank(owner);
        pool.proposeMonth(M1, Merkle.root(l), 20 ether);
        skip(3 days);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.GameUnknown.selector, ghost));
        pool.claim(M1, ghost, 10 ether, Merkle.proof(l, 0));
        assertEq(pool.reserved(), 20 ether);
    }

    // ─────────────────────────────────────────────────────────────── who gets paid ──

    function test_claimByAnotherGamesWalletPaysTheClaimedGame() public {
        bytes32[] memory l = _propose3(M1);
        skip(3 days);
        vm.prank(dev2);
        pool.claim(M1, G1, 100 ether, Merkle.proof(l, 0));
        assertEq(og.balanceOf(dev1), 100 ether);
        assertEq(og.balanceOf(dev2), 0);
    }

    function test_payoutMovedTwice_onlyLatestWalletIsPaid_andOldWalletLosesControl() public {
        bytes32[] memory l = _propose3(M1);
        address mid = makeAddr("mid");
        address last = makeAddr("last");
        vm.prank(dev1);
        pool.changePayout(G1, mid);
        vm.prank(dev1);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.NotPayout.selector, G1, dev1));
        pool.changePayout(G1, dev1);
        vm.prank(mid);
        pool.changePayout(G1, last);

        skip(3 days);
        vm.prank(dev1);
        pool.claim(M1, G1, 100 ether, Merkle.proof(l, 0));
        assertEq(og.balanceOf(last), 100 ether);
        assertEq(og.balanceOf(mid), 0);
        assertEq(og.balanceOf(dev1), 0);
    }

    function test_payoutChangeAfterClaimDoesNotAllowSecondClaim() public {
        bytes32[] memory l = _propose3(M1);
        skip(3 days);
        pool.claim(M1, G1, 100 ether, Merkle.proof(l, 0));
        vm.prank(dev1);
        pool.changePayout(G1, makeAddr("fresh"));
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.AlreadyClaimed.selector, M1, G1));
        pool.claim(M1, G1, 100 ether, Merkle.proof(l, 0));
    }

    function test_relistKeepsCurrentPayoutWallet() public {
        address moved = makeAddr("moved");
        vm.prank(dev1);
        pool.changePayout(G1, moved);
        vm.startPrank(owner);
        pool.delistGame(G1);
        pool.relistGame(G1);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.GameAlreadyListed.selector, G1));
        pool.listGame(G1, owner);
        vm.stopPrank();
        (address payout, bool listed) = pool.games(G1);
        assertEq(payout, moved);
        assertTrue(listed);
    }

    // ──────────────────────────────────────────────────────────── several months at once ──

    function test_concurrentMonths_areIsolated() public {
        bytes32[] memory l1 = _propose3(M1);
        skip(10 days);
        bytes32[] memory l2 = _propose3(M2);
        skip(10 days);
        _propose3(M3);
        assertEq(pool.reserved(), 1800 ether);

        // M1 and M2 open, M3 pending.
        pool.claim(M1, G1, 100 ether, Merkle.proof(l1, 0));
        pool.claim(M2, G1, 100 ether, Merkle.proof(l2, 0));
        assertEq(og.balanceOf(dev1), 200 ether);

        vm.prank(owner);
        pool.cancelMonth(M3);
        (, uint256 r1,,,) = _month(M1);
        (, uint256 r2,,,) = _month(M2);
        assertEq(r1, 500 ether);
        assertEq(r2, 500 ether);

        // Close M1 only, sweep it: M2 untouched and still payable.
        vm.warp(_opensAt(M1) + 90 days);
        pool.sweep(M1);
        assertEq(pool.reserved(), 500 ether);
        pool.claim(M2, G3, 300 ether, Merkle.proof(l2, 2));
        assertEq(pool.reserved(), 200 ether);
        assertEq(og.balanceOf(address(pool)), 1800 ether - 500 ether);
    }

    function test_manyLeaves_allPaidExactly() public {
        uint256[3] memory sizes = [uint256(33), 64, 65];
        uint256 month = M1;
        for (uint256 s; s < sizes.length; ++s) {
            uint256 n = sizes[s];
            bytes32[] memory ids = new bytes32[](n);
            bytes32[] memory l = new bytes32[](n);
            uint256 total;
            for (uint256 i; i < n; ++i) {
                ids[i] = pool.gameId(string.concat("bulk-", vm.toString(s), "-", vm.toString(i)));
                vm.prank(owner);
                pool.listGame(ids[i], makeAddr(string.concat("bulkdev-", vm.toString(s), "-", vm.toString(i))));
                l[i] = pool.leaf(month, ids[i], (i + 1) * 1 ether);
                total += (i + 1) * 1 ether;
            }
            _fund(total);
            vm.prank(owner);
            pool.proposeMonth(month, Merkle.root(l), total);
            skip(3 days);
            for (uint256 i = n; i > 0; --i) {
                pool.claim(month, ids[i - 1], i * 1 ether, Merkle.proof(l, i - 1));
            }
            (, uint256 remaining,,,) = _month(month);
            assertEq(remaining, 0);
            month = month % 100 == 12 ? (month / 100 + 1) * 100 + 1 : month + 1;
        }
        assertEq(pool.reserved(), 0);
        assertEq(og.balanceOf(address(pool)), 0);
    }

    function test_proposeExactlyFree_thenOneMoreWeiFails() public {
        _fund(600 ether);
        bytes32 root = Merkle.root(_leaves3(M1));
        vm.prank(owner);
        pool.proposeMonth(M1, root, 600 ether);
        assertEq(pool.free(), 0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.InsufficientFree.selector, 1, 0));
        pool.proposeMonth(M2, bytes32(uint256(1)), 1);
        og.mint(address(pool), 1);
        vm.prank(owner);
        pool.proposeMonth(M2, bytes32(uint256(1)), 1);
        assertEq(pool.reserved(), 600 ether + 1);
    }

    // ─────────────────────────────────────────────────────────────────── ownership ──

    function test_ownershipHandover_pendingOwnerPowerlessUntilAccept_oldOwnerPowerlessAfter() public {
        address next = makeAddr("next");
        _fund(600 ether);
        bytes32 root = Merkle.root(_leaves3(M1));
        vm.prank(owner);
        pool.transferOwnership(next);

        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, next));
        pool.proposeMonth(M1, root, 600 ether);

        vm.prank(next);
        pool.acceptOwnership();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        pool.proposeMonth(M1, root, 600 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        pool.listGame(keccak256("x"), owner);

        vm.prank(next);
        pool.proposeMonth(M1, root, 600 ether);
        // The new owner can no more change payouts than the old one.
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.NotPayout.selector, G1, next));
        pool.changePayout(G1, next);
    }

    function test_monthsAlreadyProposedStillPayAndSweepWithoutAnOwner() public {
        bytes32[] memory l = _propose3(M1);
        vm.prank(owner);
        pool.renounceOwnership();
        assertEq(pool.owner(), address(0));
        skip(3 days);
        vm.prank(relayer);
        pool.claim(M1, G2, 200 ether, Merkle.proof(l, 1));
        assertEq(og.balanceOf(dev2), 200 ether);
        skip(90 days);
        pool.sweep(M1);
        assertEq(pool.reserved(), 0);
    }

    function test_ownerHasNoOtherTokenExit_allPublicSelectorsAccountedFor() public {
        // Every external entry point the owner could use, called with the owner as recipient where an
        // address is taken; none moves $OG to the owner.
        _fund(1000 ether);
        bytes32[] memory l = _propose3(M1);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.NotPayout.selector, G1, owner));
        pool.changePayout(G1, owner);
        skip(3 days);
        pool.claim(M1, G1, 100 ether, Merkle.proof(l, 0));
        skip(90 days);
        pool.sweep(M1);
        vm.stopPrank();
        assertEq(og.balanceOf(owner), 0);
        assertEq(og.balanceOf(address(pool)), 900 ether);
        assertEq(pool.free(), 900 ether);
    }

    // ─────────────────────────────────────────────────────────────────── reentrancy ──

    function _hookSetup()
        internal
        returns (HookToken hog, OGClubCreatorPool hpool, ReenteringPayout evil, bytes32[] memory l)
    {
        hog = new HookToken();
        hpool = new OGClubCreatorPool(IERC20(address(hog)), owner);
        evil = new ReenteringPayout(hpool);
        vm.startPrank(owner);
        hpool.listGame(G1, address(evil));
        hpool.listGame(G2, dev2);
        vm.stopPrank();
        l = new bytes32[](2);
        l[0] = hpool.leaf(M1, G1, 10 ether);
        l[1] = hpool.leaf(M1, G2, 20 ether);
        hog.mint(address(hpool), 30 ether);
        vm.prank(owner);
        hpool.proposeMonth(M1, Merkle.root(l), 30 ether);
        skip(3 days);
    }

    function test_reentrancy_claimFromPayoutHookIsBlocked() public {
        (HookToken hog, OGClubCreatorPool hpool, ReenteringPayout evil, bytes32[] memory l) = _hookSetup();
        evil.arm(ReenteringPayout.Mode.ClaimOther, M1, G2, 20 ether, Merkle.proof(l, 1));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        hpool.claim(M1, G1, 10 ether, Merkle.proof(l, 0));
        assertFalse(hpool.claimed(M1, G1));
        assertEq(hog.balanceOf(address(hpool)), 30 ether);
        assertEq(hpool.reserved(), 30 ether);
    }

    function test_reentrancy_fundFromPayoutHookIsBlocked() public {
        (, OGClubCreatorPool hpool, ReenteringPayout evil, bytes32[] memory l) = _hookSetup();
        evil.arm(ReenteringPayout.Mode.Fund, M1, bytes32(0), 0, new bytes32[](0));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        hpool.claim(M1, G1, 10 ether, Merkle.proof(l, 0));
    }

    function test_reentrancy_sweepFromPayoutHookFindsWindowOpen() public {
        (, OGClubCreatorPool hpool, ReenteringPayout evil, bytes32[] memory l) = _hookSetup();
        evil.arm(ReenteringPayout.Mode.Sweep, M1, bytes32(0), 0, new bytes32[](0));
        uint256 closesAt = START + 3 days + 90 days;
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.ClaimWindowStillOpen.selector, M1, closesAt));
        hpool.claim(M1, G1, 10 ether, Merkle.proof(l, 0));
    }

    function test_reentrancy_swallowedReentryLeavesAccountingSound() public {
        (HookToken hog, OGClubCreatorPool hpool, ReenteringPayout evil, bytes32[] memory l) = _hookSetup();
        evil.arm(ReenteringPayout.Mode.ClaimOtherSwallow, M1, G2, 20 ether, Merkle.proof(l, 1));
        hpool.claim(M1, G1, 10 ether, Merkle.proof(l, 0));
        assertTrue(evil.reentryFailed());
        assertEq(evil.reentryError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(hog.balanceOf(address(evil)), 10 ether);
        assertEq(hog.balanceOf(dev2), 0);
        assertFalse(hpool.claimed(M1, G2));
        assertEq(hpool.reserved(), 20 ether);
        assertEq(hog.balanceOf(address(hpool)), 20 ether);

        // G2 is still claimable normally afterwards.
        hpool.claim(M1, G2, 20 ether, Merkle.proof(l, 1));
        assertEq(hog.balanceOf(dev2), 20 ether);
        assertEq(hpool.reserved(), 0);
    }

    // ──────────────────────────────────────────────────────────────── odd tokens ──

    function test_tokenReturningFalse_claimAndFundRevertAndRollBack() public {
        ReturnsFalseToken fog = new ReturnsFalseToken();
        OGClubCreatorPool fpool = new OGClubCreatorPool(IERC20(address(fog)), owner);
        vm.prank(owner);
        fpool.listGame(G1, dev1);
        fog.mint(address(fpool), 10 ether);
        fog.mint(funder, 10 ether);
        bytes32 root = fpool.leaf(M1, G1, 10 ether);
        vm.prank(owner);
        fpool.proposeMonth(M1, root, 10 ether);
        skip(3 days);

        fog.breakIt();
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(fog)));
        fpool.claim(M1, G1, 10 ether, new bytes32[](0));
        assertFalse(fpool.claimed(M1, G1));
        assertEq(fpool.reserved(), 10 ether);

        vm.startPrank(funder);
        fog.approve(address(fpool), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(fog)));
        fpool.fund(1 ether);
        vm.stopPrank();
    }

    function test_tokenWithoutReturnValue_worksForFundAndClaim() public {
        NoReturnToken usdt = new NoReturnToken();
        OGClubCreatorPool upool = new OGClubCreatorPool(IERC20(address(usdt)), owner);
        vm.prank(owner);
        upool.listGame(G1, dev1);
        usdt.mint(funder, 10 ether);
        vm.startPrank(funder);
        usdt.approve(address(upool), 10 ether);
        upool.fund(10 ether);
        vm.stopPrank();
        bytes32 root = upool.leaf(M1, G1, 10 ether);
        vm.prank(owner);
        upool.proposeMonth(M1, root, 10 ether);
        skip(3 days);
        upool.claim(M1, G1, 10 ether, new bytes32[](0));
        assertEq(usdt.balanceOf(dev1), 10 ether);
        assertEq(upool.reserved(), 0);
    }

    function test_fund_exactAllowanceAndOneWei() public {
        vm.startPrank(funder);
        og.approve(address(pool), 1);
        pool.fund(1);
        assertEq(og.allowance(funder, address(pool)), 0);
        vm.expectRevert();
        pool.fund(1);
        vm.stopPrank();
        assertEq(pool.free(), 1);
    }
}
