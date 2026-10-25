// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OGClubCreatorPool} from "../src/OGClubCreatorPool.sol";
import {MockOG} from "./support/MockOG.sol";
import {FeeOnTransferToken} from "./support/FeeOnTransferToken.sol";
import {Merkle} from "./support/Merkle.sol";

contract OGClubCreatorPoolTest is Test {
    uint256 internal constant START = 1_800_000_000; // 2027-01-15, a fixed but non-round timestamp
    uint256 internal constant M1 = 202_701;
    uint256 internal constant M2 = 202_702;
    uint256 internal constant M3 = 202_703;

    MockOG internal og;
    OGClubCreatorPool internal pool;

    address internal owner = makeAddr("owner");
    address internal funder = makeAddr("funder");
    address internal stranger = makeAddr("stranger");
    address internal dev1 = makeAddr("dev1");
    address internal dev2 = makeAddr("dev2");
    address internal dev3 = makeAddr("dev3");
    address internal dev4 = makeAddr("dev4");
    address internal dev5 = makeAddr("dev5");

    bytes32 internal G1;
    bytes32 internal G2;
    bytes32 internal G3;
    bytes32 internal G4;
    bytes32 internal G5;

    function setUp() public virtual {
        vm.warp(START);
        og = new MockOG();
        pool = new OGClubCreatorPool(IERC20(address(og)), owner);

        G1 = pool.gameId("coin-dash");
        G2 = pool.gameId("rocket-run");
        G3 = pool.gameId("puzzle-pit");
        G4 = pool.gameId("lane-racer");
        G5 = pool.gameId("tower-tap");

        vm.startPrank(owner);
        pool.listGame(G1, dev1);
        pool.listGame(G2, dev2);
        pool.listGame(G3, dev3);
        pool.listGame(G4, dev4);
        pool.listGame(G5, dev5);
        vm.stopPrank();

        og.mint(funder, 1_000_000 ether);
        og.mint(stranger, 1_000_000 ether);
    }

    // ───────────────────────────────────────────────────────────────────────────── helpers ──

    function _fund(uint256 amount) internal {
        vm.startPrank(funder);
        og.approve(address(pool), amount);
        pool.fund(amount);
        vm.stopPrank();
    }

    function _leaves(uint256 month, bytes32[] memory gamesList, uint256[] memory amounts)
        internal
        view
        returns (bytes32[] memory leaves)
    {
        leaves = new bytes32[](gamesList.length);
        for (uint256 i; i < gamesList.length; ++i) {
            leaves[i] = pool.leaf(month, gamesList[i], amounts[i]);
        }
    }

    function _sum(uint256[] memory amounts) internal pure returns (uint256 s) {
        for (uint256 i; i < amounts.length; ++i) {
            s += amounts[i];
        }
    }

    /// @dev Proposes `month` with the given list, funded exactly. Returns the leaves for proofs.
    function _propose(uint256 month, bytes32[] memory gamesList, uint256[] memory amounts)
        internal
        returns (bytes32[] memory leaves)
    {
        leaves = _leaves(month, gamesList, amounts);
        uint256 total = _sum(amounts);
        if (pool.free() < total) _fund(total - pool.free());
        vm.prank(owner);
        pool.proposeMonth(month, Merkle.root(leaves), total);
    }

    function _three() internal view returns (bytes32[] memory g, uint256[] memory a) {
        g = new bytes32[](3);
        a = new uint256[](3);
        g[0] = G1;
        g[1] = G2;
        g[2] = G3;
        a[0] = 100 ether;
        a[1] = 250 ether;
        a[2] = 50 ether;
    }

    function _four() internal view returns (bytes32[] memory g, uint256[] memory a) {
        g = new bytes32[](4);
        a = new uint256[](4);
        g[0] = G1;
        g[1] = G2;
        g[2] = G3;
        g[3] = G4;
        a[0] = 10 ether;
        a[1] = 20 ether;
        a[2] = 30 ether;
        a[3] = 40 ether;
    }

    function _opensAt(uint256 month) internal view returns (uint64 opensAt) {
        (,,, opensAt,,) = pool.months(month);
    }

    function _remaining(uint256 month) internal view returns (uint256 remaining) {
        (,, remaining,,,) = pool.months(month);
    }

    // ─────────────────────────────────────────────────────────────────────────────── setup ──

    function test_constructor() public view {
        assertEq(address(pool.token()), address(og));
        assertEq(pool.owner(), owner);
        assertEq(pool.CLAIM_DELAY(), 3 days);
        assertEq(pool.CLAIM_PERIOD(), 90 days);
        assertEq(pool.reserved(), 0);
        assertEq(pool.free(), 0);
    }

    function test_constructor_revertsOnZeroToken() public {
        vm.expectRevert(OGClubCreatorPool.ZeroAddress.selector);
        new OGClubCreatorPool(IERC20(address(0)), owner);
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new OGClubCreatorPool(IERC20(address(og)), address(0));
    }

    function test_noEthAccepted() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(pool).call{value: 1 ether}("");
        assertFalse(ok, "pool must not accept ETH");
        assertEq(address(pool).balance, 0);
    }

    function test_ownershipIsTwoStep() public {
        vm.prank(owner);
        pool.transferOwnership(stranger);
        assertEq(pool.owner(), owner);
        assertEq(pool.pendingOwner(), stranger);
        vm.prank(stranger);
        pool.acceptOwnership();
        assertEq(pool.owner(), stranger);
    }

    // ─────────────────────────────────────────────────────────────────────────────── games ──

    function test_gameId() public view {
        assertEq(pool.gameId("coin-dash"), keccak256(bytes("coin-dash")));
        assertEq(pool.gameId("coin-dash"), G1);
    }

    function test_listGame_setsPayoutAndListed() public view {
        (address payout, bool listed) = pool.games(G1);
        assertEq(payout, dev1);
        assertTrue(listed);
        assertEq(pool.listedAt(G1), START);
        assertEq(pool.listedAt(pool.gameId("ghost")), 0);
    }

    function test_listGame_emits() public {
        bytes32 id = pool.gameId("new-game");
        vm.expectEmit(address(pool));
        emit OGClubCreatorPool.GameListed(id, dev1);
        vm.prank(owner);
        pool.listGame(id, dev1);
    }

    function test_listGame_onlyOwner() public {
        bytes32 id = pool.gameId("x");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        pool.listGame(id, dev1);
    }

    function test_listGame_revertsOnZeroPayout() public {
        bytes32 id = pool.gameId("x");
        vm.expectRevert(OGClubCreatorPool.ZeroAddress.selector);
        vm.prank(owner);
        pool.listGame(id, address(0));
    }

    function test_listGame_revertsOnPoolAsPayout() public {
        bytes32 id = pool.gameId("x");
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.InvalidPayout.selector, address(pool)));
        vm.prank(owner);
        pool.listGame(id, address(pool));
    }

    function test_listGame_onlyOnceEver() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.GameAlreadyListed.selector, G1));
        pool.listGame(G1, dev2);
        // Even after a delist the id cannot be listed again; relist is the only path.
        pool.delistGame(G1);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.GameAlreadyListed.selector, G1));
        pool.listGame(G1, dev2);
        vm.stopPrank();
    }

    function test_delistRelist() public {
        vm.startPrank(owner);
        vm.expectEmit(address(pool));
        emit OGClubCreatorPool.GameDelisted(G1);
        pool.delistGame(G1);
        (address payout, bool listed) = pool.games(G1);
        assertEq(payout, dev1, "payout kept");
        assertFalse(listed);

        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.GameNotListed.selector, G1));
        pool.delistGame(G1);

        vm.expectEmit(address(pool));
        emit OGClubCreatorPool.GameRelisted(G1);
        pool.relistGame(G1);
        (, listed) = pool.games(G1);
        assertTrue(listed);

        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.GameAlreadyActive.selector, G1));
        pool.relistGame(G1);
        vm.stopPrank();
    }

    function test_delistRelist_unknownGame() public {
        bytes32 id = pool.gameId("ghost");
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.GameUnknown.selector, id));
        pool.delistGame(id);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.GameUnknown.selector, id));
        pool.relistGame(id);
        vm.stopPrank();
    }

    function test_delistRelist_onlyOwner() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        pool.delistGame(G1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        pool.relistGame(G1);
        vm.stopPrank();
    }

    function test_changePayout_byPayoutWallet() public {
        address newWallet = makeAddr("dev1-new");
        vm.expectEmit(address(pool));
        emit OGClubCreatorPool.PayoutChanged(G1, dev1, newWallet);
        vm.prank(dev1);
        pool.changePayout(G1, newWallet);
        (address payout,) = pool.games(G1);
        assertEq(payout, newWallet);

        // The old wallet lost control, the new one has it.
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.NotPayout.selector, G1, dev1));
        vm.prank(dev1);
        pool.changePayout(G1, dev1);
        vm.prank(newWallet);
        pool.changePayout(G1, dev1);
        (payout,) = pool.games(G1);
        assertEq(payout, dev1);
    }

    function test_changePayout_worksWhenDelisted() public {
        vm.prank(owner);
        pool.delistGame(G1);
        vm.prank(dev1);
        pool.changePayout(G1, dev2);
        (address payout, bool listed) = pool.games(G1);
        assertEq(payout, dev2);
        assertFalse(listed);
    }

    function test_changePayout_ownerCannot() public {
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.NotPayout.selector, G1, owner));
        vm.prank(owner);
        pool.changePayout(G1, owner);
    }

    function test_changePayout_strangerCannot() public {
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.NotPayout.selector, G1, stranger));
        vm.prank(stranger);
        pool.changePayout(G1, stranger);
    }

    function test_changePayout_unknownGame() public {
        bytes32 id = pool.gameId("ghost");
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.GameUnknown.selector, id));
        vm.prank(dev1);
        pool.changePayout(id, dev2);
    }

    function test_changePayout_rejectsZeroSelfAndPool() public {
        vm.startPrank(dev1);
        vm.expectRevert(OGClubCreatorPool.ZeroAddress.selector);
        pool.changePayout(G1, address(0));
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.InvalidPayout.selector, dev1));
        pool.changePayout(G1, dev1);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.InvalidPayout.selector, address(pool)));
        pool.changePayout(G1, address(pool));
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────────────────────── money in ──

    function test_fund_pullsExactAmount() public {
        vm.startPrank(funder);
        og.approve(address(pool), 500 ether);
        vm.expectEmit(address(pool));
        emit OGClubCreatorPool.Funded(funder, 500 ether);
        pool.fund(500 ether);
        vm.stopPrank();
        assertEq(og.balanceOf(address(pool)), 500 ether);
        assertEq(pool.free(), 500 ether);
        assertEq(pool.reserved(), 0);
    }

    function test_fund_revertsOnZero() public {
        vm.expectRevert(OGClubCreatorPool.ZeroAmount.selector);
        vm.prank(funder);
        pool.fund(0);
    }

    function test_fund_revertsWithoutAllowance() public {
        vm.expectRevert();
        vm.prank(funder);
        pool.fund(1 ether);
    }

    function test_plainTransferCountsAsFree() public {
        vm.prank(funder);
        og.transfer(address(pool), 123 ether);
        assertEq(pool.free(), 123 ether);
    }

    function test_feeOnTransfer_fundReverts() public {
        FeeOnTransferToken fee = new FeeOnTransferToken(false);
        OGClubCreatorPool feePool = new OGClubCreatorPool(IERC20(address(fee)), owner);
        fee.mint(funder, 1000 ether);
        vm.startPrank(funder);
        fee.approve(address(feePool), 1000 ether);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.BalanceMismatch.selector, 100 ether, 99 ether));
        feePool.fund(100 ether);
        vm.stopPrank();
    }

    function test_feeOnTransfer_claimReverts() public {
        // A token that debits the sender more than the amount: the pool's exact send check catches it.
        _feeClaimReverts(true, 101 ether);
    }

    function test_feeOnTransfer_claimReverts_recipientCharged() public {
        // The usual shape: the recipient gets less than sent. The pool's own balance drops by exactly
        // the amount, so only the recipient-side check catches it; the game is never credited for
        // tokens it did not receive.
        _feeClaimReverts(false, 99 ether);
    }

    function _feeClaimReverts(bool chargeSender, uint256 observed) internal {
        FeeOnTransferToken fee = new FeeOnTransferToken(chargeSender);
        OGClubCreatorPool feePool = new OGClubCreatorPool(IERC20(address(fee)), owner);
        vm.prank(owner);
        feePool.listGame(G1, dev1);
        fee.mint(address(feePool), 1000 ether); // mint lands exactly, so free() is 1000

        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = feePool.leaf(M1, G1, 100 ether);
        bytes32 root = Merkle.root(leaves);
        vm.prank(owner);
        feePool.proposeMonth(M1, root, 100 ether);
        skip(3 days);

        bytes32[] memory proof = Merkle.proof(leaves, 0);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.BalanceMismatch.selector, 100 ether, observed));
        feePool.claim(M1, G1, 100 ether, proof);
        // The revert rolled everything back.
        assertEq(feePool.reserved(), 100 ether);
        assertFalse(feePool.claimed(M1, G1));
        assertEq(fee.balanceOf(dev1), 0);
    }

    // ────────────────────────────────────────────────────────────────────────────── months ──

    function test_isValidMonth() public view {
        assertTrue(pool.isValidMonth(202_601));
        assertTrue(pool.isValidMonth(202_612));
        assertTrue(pool.isValidMonth(999_912));
        assertFalse(pool.isValidMonth(202_600));
        assertFalse(pool.isValidMonth(202_613));
        assertFalse(pool.isValidMonth(202_512));
        assertFalse(pool.isValidMonth(0));
        assertFalse(pool.isValidMonth(1_000_001));
    }

    function test_proposeMonth_reservesAndSchedules() public {
        (bytes32[] memory g, uint256[] memory a) = _three();
        _fund(1000 ether);
        bytes32 root = Merkle.root(_leaves(M1, g, a));
        vm.expectEmit(address(pool));
        emit OGClubCreatorPool.MonthProposed(M1, root, 400 ether, uint64(START + 3 days));
        vm.prank(owner);
        pool.proposeMonth(M1, root, 400 ether);

        (bytes32 r, uint256 total, uint256 remaining, uint64 opensAt, bool cancelled, bool swept) = pool.months(M1);
        assertEq(r, root);
        assertEq(total, 400 ether);
        assertEq(remaining, 400 ether);
        assertEq(opensAt, START + 3 days);
        assertFalse(cancelled);
        assertFalse(swept);
        assertEq(pool.reserved(), 400 ether);
        assertEq(pool.free(), 600 ether);
        assertEq(pool.lastMonth(), M1);
        assertEq(uint256(pool.status(M1)), uint256(OGClubCreatorPool.MonthStatus.Pending));
        assertFalse(pool.isOpen(M1));
    }

    function test_proposeMonth_onlyOwner() public {
        _fund(10 ether);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        pool.proposeMonth(M1, bytes32(uint256(1)), 1 ether);
    }

    function test_proposeMonth_reverts() public {
        _fund(10 ether);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.InvalidMonth.selector, 202_613));
        pool.proposeMonth(202_613, bytes32(uint256(1)), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.InvalidMonth.selector, 202_512));
        pool.proposeMonth(202_512, bytes32(uint256(1)), 1 ether);
        vm.expectRevert(OGClubCreatorPool.ZeroRoot.selector);
        pool.proposeMonth(M1, bytes32(0), 1 ether);
        vm.expectRevert(OGClubCreatorPool.ZeroAmount.selector);
        pool.proposeMonth(M1, bytes32(uint256(1)), 0);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.InsufficientFree.selector, 11 ether, 10 ether));
        pool.proposeMonth(M1, bytes32(uint256(1)), 11 ether);

        pool.proposeMonth(M2, bytes32(uint256(1)), 4 ether);
        // Same month again while it is live, and an earlier month, are both refused.
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.MonthNotAfterLast.selector, M2, M2));
        pool.proposeMonth(M2, bytes32(uint256(2)), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.MonthNotAfterLast.selector, M1, M2));
        pool.proposeMonth(M1, bytes32(uint256(2)), 1 ether);
        // Reservation accumulates: only 6 remain free.
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.InsufficientFree.selector, 7 ether, 6 ether));
        pool.proposeMonth(M3, bytes32(uint256(2)), 7 ether);
        pool.proposeMonth(M3, bytes32(uint256(2)), 6 ether);
        assertEq(pool.reserved(), 10 ether);
        assertEq(pool.free(), 0);
        vm.stopPrank();
    }

    // ────────────────────────────────────────────────────────────────────────────── claims ──

    function test_fullMonth_oddLeaves() public {
        (bytes32[] memory g, uint256[] memory a) = _three();
        bytes32[] memory leaves = _propose(M1, g, a);
        skip(3 days);
        assertTrue(pool.isOpen(M1));
        assertEq(uint256(pool.status(M1)), uint256(OGClubCreatorPool.MonthStatus.Open));

        for (uint256 i; i < g.length; ++i) {
            (address payout,) = pool.games(g[i]);
            uint256 before = og.balanceOf(payout);
            vm.expectEmit(address(pool));
            emit OGClubCreatorPool.Claimed(M1, g[i], payout, a[i], stranger);
            vm.prank(stranger);
            pool.claim(M1, g[i], a[i], Merkle.proof(leaves, i));
            assertEq(og.balanceOf(payout) - before, a[i]);
            assertTrue(pool.claimed(M1, g[i]));
        }
        assertEq(_remaining(M1), 0);
        assertEq(pool.reserved(), 0);
        assertEq(og.balanceOf(address(pool)), 0);
        assertEq(og.balanceOf(stranger), 1_000_000 ether, "caller got nothing");
    }

    function test_fullMonth_evenLeaves() public {
        (bytes32[] memory g, uint256[] memory a) = _four();
        bytes32[] memory leaves = _propose(M1, g, a);
        skip(3 days);
        for (uint256 i = g.length; i > 0; --i) {
            // reverse order: order of claims does not matter
            uint256 idx = i - 1;
            (address payout,) = pool.games(g[idx]);
            pool.claim(M1, g[idx], a[idx], Merkle.proof(leaves, idx));
            assertEq(og.balanceOf(payout), a[idx]);
        }
        assertEq(_remaining(M1), 0);
        assertEq(pool.reserved(), 0);
    }

    function test_fullMonth_fiveLeavesAndSurplusFree() public {
        bytes32[] memory g = new bytes32[](5);
        uint256[] memory a = new uint256[](5);
        g[0] = G1;
        g[1] = G2;
        g[2] = G3;
        g[3] = G4;
        g[4] = G5;
        for (uint256 i; i < 5; ++i) {
            a[i] = (i + 1) * 7 ether;
        }
        _fund(1000 ether);
        bytes32[] memory leaves = _propose(M1, g, a);
        uint256 total = _sum(a);
        assertEq(pool.free(), 1000 ether - total);
        skip(3 days);
        for (uint256 i; i < 5; ++i) {
            pool.claim(M1, g[i], a[i], Merkle.proof(leaves, i));
        }
        assertEq(pool.reserved(), 0);
        assertEq(pool.free(), 1000 ether - total);
        assertEq(og.balanceOf(dev5), 35 ether);
    }

    function test_singleLeafMonth() public {
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = pool.leaf(M1, G1, 42 ether);
        _fund(42 ether);
        vm.prank(owner);
        pool.proposeMonth(M1, Merkle.root(leaves), 42 ether);
        skip(3 days);
        pool.claim(M1, G1, 42 ether, new bytes32[](0));
        assertEq(og.balanceOf(dev1), 42 ether);
    }

    function test_anyoneCanPushClaim_payoutWalletReceives() public {
        (bytes32[] memory g, uint256[] memory a) = _three();
        bytes32[] memory leaves = _propose(M1, g, a);
        skip(3 days);
        address[3] memory callers = [stranger, owner, dev3];
        for (uint256 i; i < 3; ++i) {
            uint256 callerBefore = og.balanceOf(callers[i]);
            (address payout,) = pool.games(g[i]);
            uint256 payoutBefore = og.balanceOf(payout);
            vm.prank(callers[i]);
            pool.claim(M1, g[i], a[i], Merkle.proof(leaves, i));
            assertEq(og.balanceOf(payout) - payoutBefore, a[i]);
            if (callers[i] != payout) assertEq(og.balanceOf(callers[i]), callerBefore);
        }
    }

    function test_payoutChangedBeforeClaim_paysNewWallet() public {
        (bytes32[] memory g, uint256[] memory a) = _three();
        bytes32[] memory leaves = _propose(M1, g, a);
        address newWallet = makeAddr("dev1-new");
        vm.prank(dev1);
        pool.changePayout(G1, newWallet);
        skip(3 days);
        pool.claim(M1, G1, a[0], Merkle.proof(leaves, 0));
        assertEq(og.balanceOf(newWallet), a[0]);
        assertEq(og.balanceOf(dev1), 0);
    }

    function test_delistedGameCanStillClaim() public {
        (bytes32[] memory g, uint256[] memory a) = _three();
        bytes32[] memory leaves = _propose(M1, g, a);
        vm.prank(owner);
        pool.delistGame(G2);
        skip(3 days);
        pool.claim(M1, G2, a[1], Merkle.proof(leaves, 1));
        assertEq(og.balanceOf(dev2), a[1]);
    }

    function test_claim_revertsEarly() public {
        (bytes32[] memory g, uint256[] memory a) = _three();
        bytes32[] memory leaves = _propose(M1, g, a);
        uint64 opensAt = _opensAt(M1);
        vm.warp(opensAt - 1);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.ClaimNotOpen.selector, M1, opensAt));
        pool.claim(M1, G1, a[0], Merkle.proof(leaves, 0));
        // exactly at opensAt it works
        vm.warp(opensAt);
        pool.claim(M1, G1, a[0], Merkle.proof(leaves, 0));
    }

    function test_claim_revertsLate() public {
        (bytes32[] memory g, uint256[] memory a) = _three();
        bytes32[] memory leaves = _propose(M1, g, a);
        uint256 closesAt = _opensAt(M1) + 90 days;
        vm.warp(closesAt - 1);
        pool.claim(M1, G1, a[0], Merkle.proof(leaves, 0));
        vm.warp(closesAt);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.ClaimClosed.selector, M1, closesAt));
        pool.claim(M1, G2, a[1], Merkle.proof(leaves, 1));
        assertEq(uint256(pool.status(M1)), uint256(OGClubCreatorPool.MonthStatus.Closed));
        assertFalse(pool.isOpen(M1));
    }

    function test_claim_revertsTwice() public {
        (bytes32[] memory g, uint256[] memory a) = _three();
        bytes32[] memory leaves = _propose(M1, g, a);
        skip(3 days);
        pool.claim(M1, G1, a[0], Merkle.proof(leaves, 0));
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.AlreadyClaimed.selector, M1, G1));
        pool.claim(M1, G1, a[0], Merkle.proof(leaves, 0));
    }

    function test_claim_revertsWrongLeaf() public {
        (bytes32[] memory g, uint256[] memory a) = _three();
        bytes32[] memory leaves = _propose(M1, g, a);
        skip(3 days);
        bytes32[] memory proof0 = Merkle.proof(leaves, 0);
        // wrong amount
        vm.expectRevert(OGClubCreatorPool.InvalidProof.selector);
        pool.claim(M1, G1, a[0] + 1, proof0);
        // wrong game with G1's proof
        vm.expectRevert(OGClubCreatorPool.InvalidProof.selector);
        pool.claim(M1, G4, a[0], proof0);
        // right leaf, wrong proof
        vm.expectRevert(OGClubCreatorPool.InvalidProof.selector);
        pool.claim(M1, G1, a[0], Merkle.proof(leaves, 1));
        // leaf from another month id
        _fund(_sum(a));
        bytes32 root2 = Merkle.root(_leaves(M2, g, a));
        vm.prank(owner);
        pool.proposeMonth(M2, root2, _sum(a));
        skip(3 days);
        vm.expectRevert(OGClubCreatorPool.InvalidProof.selector);
        pool.claim(M2, G1, a[0], proof0);
        // zero amount
        vm.expectRevert(OGClubCreatorPool.ZeroAmount.selector);
        pool.claim(M1, G1, 0, proof0);
    }

    function test_claim_revertsUnknownGame() public {
        bytes32 ghost = pool.gameId("ghost");
        bytes32[] memory g = new bytes32[](2);
        uint256[] memory a = new uint256[](2);
        g[0] = G1;
        g[1] = ghost;
        a[0] = 1 ether;
        a[1] = 2 ether;
        bytes32[] memory leaves = _propose(M1, g, a);
        skip(3 days);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.GameUnknown.selector, ghost));
        pool.claim(M1, ghost, 2 ether, Merkle.proof(leaves, 1));
    }

    function test_claim_revertsOverBudget() public {
        // A root whose leaves add up to more than the month's total: the last claim must fail.
        (bytes32[] memory g, uint256[] memory a) = _three(); // 400 total
        bytes32[] memory leaves = _leaves(M1, g, a);
        _fund(300 ether);
        vm.prank(owner);
        pool.proposeMonth(M1, Merkle.root(leaves), 300 ether);
        skip(3 days);
        pool.claim(M1, G2, a[1], Merkle.proof(leaves, 1)); // 250
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.ExceedsRemaining.selector, a[0], 50 ether));
        pool.claim(M1, G1, a[0], Merkle.proof(leaves, 0)); // 100 > 50
        pool.claim(M1, G3, a[2], Merkle.proof(leaves, 2)); // 50 == 50
        assertEq(_remaining(M1), 0);
        assertEq(og.balanceOf(address(pool)), 0);
    }

    function test_claim_revertsUnknownOrCancelledMonth() public {
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.MonthNotProposed.selector, M1));
        pool.claim(M1, G1, 1 ether, new bytes32[](0));

        (bytes32[] memory g, uint256[] memory a) = _three();
        bytes32[] memory leaves = _propose(M1, g, a);
        vm.prank(owner);
        pool.cancelMonth(M1);
        skip(3 days);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.MonthWasCancelled.selector, M1));
        pool.claim(M1, G1, a[0], Merkle.proof(leaves, 0));
    }

    function test_claim_cannotPayFromOtherMonthsReserve() public {
        // Two open months; draining one leaves the other's reserve untouched.
        (bytes32[] memory g, uint256[] memory a) = _three();
        bytes32[] memory l1 = _propose(M1, g, a);
        bytes32[] memory l2 = _propose(M2, g, a);
        skip(3 days);
        for (uint256 i; i < 3; ++i) {
            pool.claim(M1, g[i], a[i], Merkle.proof(l1, i));
        }
        assertEq(pool.reserved(), 400 ether);
        assertEq(_remaining(M2), 400 ether);
        assertEq(og.balanceOf(address(pool)), 400 ether);
        pool.claim(M2, G1, a[0], Merkle.proof(l2, 0));
        assertEq(pool.reserved(), 300 ether);
    }

    // ────────────────────────────────────────────────────────────────────────────── cancel ──

    function test_cancelMonth_releasesAndAllowsRepropose() public {
        (bytes32[] memory g, uint256[] memory a) = _three();
        _propose(M1, g, a);
        assertEq(pool.reserved(), 400 ether);
        skip(3 days - 1);
        vm.expectEmit(address(pool));
        emit OGClubCreatorPool.MonthCancelled(M1, 400 ether);
        vm.prank(owner);
        pool.cancelMonth(M1);
        assertEq(pool.reserved(), 0);
        assertEq(pool.free(), 400 ether);
        assertEq(_remaining(M1), 0);
        assertEq(uint256(pool.status(M1)), uint256(OGClubCreatorPool.MonthStatus.Cancelled));

        // Cancelled twice: refused. Sweep of a cancelled month: refused.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.MonthWasCancelled.selector, M1));
        pool.cancelMonth(M1);
        skip(100 days);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.MonthWasCancelled.selector, M1));
        pool.sweep(M1);

        // Re-propose the same month with a corrected list; it overwrites.
        uint256[] memory b = new uint256[](3);
        b[0] = 1 ether;
        b[1] = 2 ether;
        b[2] = 3 ether;
        bytes32[] memory leaves = _leaves(M1, g, b);
        vm.prank(owner);
        pool.proposeMonth(M1, Merkle.root(leaves), 6 ether);
        (bytes32 root, uint256 total, uint256 remaining, uint64 opensAt, bool cancelled,) = pool.months(M1);
        assertEq(root, Merkle.root(leaves));
        assertEq(total, 6 ether);
        assertEq(remaining, 6 ether);
        assertEq(opensAt, block.timestamp + 3 days);
        assertFalse(cancelled);
        assertEq(pool.reserved(), 6 ether);
        assertEq(pool.lastMonth(), M1);

        skip(3 days);
        pool.claim(M1, G3, 3 ether, Merkle.proof(leaves, 2));
        assertEq(og.balanceOf(dev3), 3 ether);
    }

    function test_cancelMonth_tooLate() public {
        (bytes32[] memory g, uint256[] memory a) = _three();
        _propose(M1, g, a);
        uint64 opensAt = _opensAt(M1);
        vm.warp(opensAt);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.MonthAlreadyOpen.selector, M1, opensAt));
        pool.cancelMonth(M1);
        // And still not after the window closes: the money stays owed until swept, never to the owner.
        vm.warp(opensAt + 90 days);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.MonthAlreadyOpen.selector, M1, opensAt));
        pool.cancelMonth(M1);
    }

    function test_cancelMonth_onlyOwnerAndMustExist() public {
        (bytes32[] memory g, uint256[] memory a) = _three();
        _propose(M1, g, a);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        pool.cancelMonth(M1);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.MonthNotProposed.selector, M2));
        vm.prank(owner);
        pool.cancelMonth(M2);
    }

    function test_cancelMonth_restoresLastMonthAfterTypo() public {
        // A mistyped far-future id is undone by cancelling it: lastMonth goes back to what it was.
        _fund(10 ether);
        vm.startPrank(owner);
        pool.proposeMonth(999_912, bytes32(uint256(1)), 1 ether);
        assertEq(pool.lastMonth(), 999_912);
        assertEq(pool.lastMonthBefore(999_912), 0);
        pool.cancelMonth(999_912);
        assertEq(pool.lastMonth(), 0, "restored");
        assertEq(pool.free(), 10 ether);
        pool.proposeMonth(M1, bytes32(uint256(1)), 1 ether);
        assertEq(pool.lastMonth(), M1);

        // Same with a live month below: M3 typed for M2, cancelled, M2 goes through.
        pool.proposeMonth(M3, bytes32(uint256(1)), 1 ether);
        assertEq(pool.lastMonthBefore(M3), M1);
        pool.cancelMonth(M3);
        assertEq(pool.lastMonth(), M1);
        pool.proposeMonth(M2, bytes32(uint256(1)), 1 ether);
        assertEq(pool.lastMonth(), M2);
        // The cancelled M3 can still be proposed later, overwriting the cancelled record.
        pool.proposeMonth(M3, bytes32(uint256(2)), 1 ether);
        assertEq(pool.lastMonthBefore(M3), M2);
        (bytes32 root,,,, bool cancelled,) = pool.months(M3);
        assertEq(root, bytes32(uint256(2)));
        assertFalse(cancelled);
        vm.stopPrank();
    }

    function test_cancelMonth_onlyLastMonthMovesLastMonth() public {
        // Cancelling a month below the last one leaves lastMonth alone: live later months stay the bar.
        _fund(10 ether);
        vm.startPrank(owner);
        pool.proposeMonth(M1, bytes32(uint256(1)), 1 ether);
        pool.proposeMonth(M2, bytes32(uint256(1)), 1 ether);
        pool.cancelMonth(M1);
        assertEq(pool.lastMonth(), M2);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.MonthNotAfterLast.selector, M1, M2));
        pool.proposeMonth(M1, bytes32(uint256(1)), 1 ether);
        vm.stopPrank();
    }

    function test_cancelMonth_walksBackOverCancelledMonths() public {
        // M1 live, M2 and M3 proposed, M2 cancelled while M3 live, then M3 cancelled: lastMonth
        // skips the cancelled M2 and lands on M1, so M2 can be proposed again as a normal month.
        _fund(10 ether);
        vm.startPrank(owner);
        pool.proposeMonth(M1, bytes32(uint256(1)), 1 ether);
        pool.proposeMonth(M2, bytes32(uint256(1)), 1 ether);
        pool.proposeMonth(M3, bytes32(uint256(1)), 1 ether);
        pool.cancelMonth(M2);
        assertEq(pool.lastMonth(), M3);
        pool.cancelMonth(M3);
        assertEq(pool.lastMonth(), M1);
        assertEq(pool.reserved(), 1 ether);
        pool.proposeMonth(M2, bytes32(uint256(3)), 2 ether);
        assertEq(pool.lastMonth(), M2);
        assertEq(pool.lastMonthBefore(M2), M1);
        assertEq(pool.reserved(), 3 ether);
        vm.stopPrank();
    }

    function test_cancelMonth_lastMonthNeverDropsBelowOpenMonth() public {
        // Once M1 is open it is permanent, and no cancel sequence lets an id <= M1 be proposed.
        _fund(10 ether);
        vm.startPrank(owner);
        pool.proposeMonth(M1, bytes32(uint256(1)), 1 ether);
        skip(3 days);
        pool.proposeMonth(M3, bytes32(uint256(1)), 1 ether);
        pool.cancelMonth(M3);
        assertEq(pool.lastMonth(), M1);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.MonthNotAfterLast.selector, M1, M1));
        pool.proposeMonth(M1, bytes32(uint256(1)), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.MonthNotAfterLast.selector, 202_612, M1));
        pool.proposeMonth(202_612, bytes32(uint256(1)), 1 ether);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────── recipients fixed at proposal ──

    function test_claim_revertsForGameListedAfterProposal() public {
        // A leaf for an id that is not listed when the month is proposed stays unclaimable even if
        // the owner lists that id afterwards: the owner cannot pick the recipient once the month
        // is out of its reach.
        bytes32 newGame = pool.gameId("new-game");
        address late = makeAddr("late-wallet");
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = pool.leaf(M1, newGame, 100 ether);
        _fund(100 ether);
        vm.prank(owner);
        pool.proposeMonth(M1, Merkle.root(leaves), 100 ether);
        skip(3 days);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.MonthAlreadyOpen.selector, M1, uint64(START + 3 days)));
        pool.cancelMonth(M1);

        vm.prank(owner);
        pool.listGame(newGame, late);
        assertEq(pool.listedAt(newGame), START + 3 days);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.GameListedAfterProposal.selector, newGame, M1));
        pool.claim(M1, newGame, 100 ether, new bytes32[](0));
        assertEq(og.balanceOf(late), 0);

        // Listing one second after the proposal is also too late.
        bytes32 other = pool.gameId("other-game");
        bytes32[] memory l2 = new bytes32[](1);
        l2[0] = pool.leaf(M2, other, 1 ether);
        _fund(1 ether);
        vm.prank(owner);
        pool.proposeMonth(M2, Merkle.root(l2), 1 ether);
        skip(1);
        vm.prank(owner);
        pool.listGame(other, late);
        skip(3 days);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.GameListedAfterProposal.selector, other, M2));
        pool.claim(M2, other, 1 ether, new bytes32[](0));

        // The money stays owed to the month and is swept back to free(), never to the owner.
        skip(90 days);
        pool.sweep(M1);
        pool.sweep(M2);
        assertEq(pool.free(), 101 ether);
        assertEq(og.balanceOf(owner), 0);
    }

    function test_claim_gameListedInProposalBlockCanClaim() public {
        // Listed in the same block as the proposal: known when the review starts, so allowed.
        bytes32 newGame = pool.gameId("new-game");
        address wallet = makeAddr("new-wallet");
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = pool.leaf(M1, newGame, 5 ether);
        _fund(5 ether);
        vm.startPrank(owner);
        pool.proposeMonth(M1, Merkle.root(leaves), 5 ether);
        pool.listGame(newGame, wallet);
        vm.stopPrank();
        skip(3 days);
        pool.claim(M1, newGame, 5 ether, new bytes32[](0));
        assertEq(og.balanceOf(wallet), 5 ether);
    }

    function test_claim_lateListedGameIsPaidByTheNextMonth() public {
        bytes32 newGame = pool.gameId("new-game");
        address wallet = makeAddr("new-wallet");
        (bytes32[] memory g, uint256[] memory a) = _three();
        _propose(M1, g, a);
        skip(1 days);
        vm.prank(owner);
        pool.listGame(newGame, wallet);

        // Next month includes the new game; it is paid like any other.
        bytes32[] memory g2 = new bytes32[](2);
        uint256[] memory a2 = new uint256[](2);
        g2[0] = G1;
        g2[1] = newGame;
        a2[0] = 1 ether;
        a2[1] = 2 ether;
        bytes32[] memory l2 = _propose(M2, g2, a2);
        skip(3 days);
        pool.claim(M2, newGame, 2 ether, Merkle.proof(l2, 1));
        assertEq(og.balanceOf(wallet), 2 ether);
    }

    function test_claim_reproposedMonthAcceptsGamesListedBeforeTheReproposal() public {
        // Cancel and re-propose restarts the review, so a game listed in between is fine.
        bytes32 newGame = pool.gameId("new-game");
        address wallet = makeAddr("new-wallet");
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = pool.leaf(M1, newGame, 5 ether);
        _fund(5 ether);
        vm.startPrank(owner);
        pool.proposeMonth(M1, Merkle.root(leaves), 5 ether);
        skip(1 days);
        pool.listGame(newGame, wallet);
        pool.cancelMonth(M1);
        skip(1);
        pool.proposeMonth(M1, Merkle.root(leaves), 5 ether);
        vm.stopPrank();
        skip(3 days);
        pool.claim(M1, newGame, 5 ether, new bytes32[](0));
        assertEq(og.balanceOf(wallet), 5 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────────── sweep ──

    function test_sweep_returnsUnclaimedToFreeAndReuse() public {
        (bytes32[] memory g, uint256[] memory a) = _three();
        bytes32[] memory leaves = _propose(M1, g, a);
        skip(3 days);
        pool.claim(M1, G1, a[0], Merkle.proof(leaves, 0)); // 100 claimed, 300 unclaimed
        uint256 closesAt = _opensAt(M1) + 90 days;

        vm.warp(closesAt - 1);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.ClaimWindowStillOpen.selector, M1, closesAt));
        pool.sweep(M1);

        vm.warp(closesAt);
        vm.expectEmit(address(pool));
        emit OGClubCreatorPool.MonthSwept(M1, 300 ether);
        vm.prank(stranger);
        pool.sweep(M1);
        assertEq(pool.reserved(), 0);
        assertEq(pool.free(), 300 ether);
        assertEq(og.balanceOf(address(pool)), 300 ether, "nothing left the pool");
        assertEq(og.balanceOf(owner), 0, "owner got nothing");
        assertEq(og.balanceOf(stranger), 1_000_000 ether, "sweeper got nothing");
        assertEq(uint256(pool.status(M1)), uint256(OGClubCreatorPool.MonthStatus.Swept));

        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.NothingToSweep.selector, M1));
        pool.sweep(M1);
        // Late claims against the swept month are still refused as closed.
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.ClaimClosed.selector, M1, closesAt));
        pool.claim(M1, G2, a[1], Merkle.proof(leaves, 1));

        // The swept 300 funds the next month without new deposits.
        bytes32[] memory l2 = _leaves(M2, g, a);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.InsufficientFree.selector, 400 ether, 300 ether));
        pool.proposeMonth(M2, Merkle.root(l2), 400 ether);
        vm.prank(owner);
        pool.proposeMonth(M2, Merkle.root(l2), 300 ether);
        skip(3 days);
        pool.claim(M2, G2, a[1], Merkle.proof(l2, 1));
        pool.claim(M2, G3, a[2], Merkle.proof(l2, 2));
        assertEq(og.balanceOf(dev2), 250 ether);
        assertEq(og.balanceOf(dev3), 50 ether);
    }

    function test_sweep_fullyClaimedMonthIsNoop() public {
        (bytes32[] memory g, uint256[] memory a) = _three();
        bytes32[] memory leaves = _propose(M1, g, a);
        skip(3 days);
        for (uint256 i; i < 3; ++i) {
            pool.claim(M1, g[i], a[i], Merkle.proof(leaves, i));
        }
        skip(90 days);
        pool.sweep(M1); // releases 0, marks swept
        assertEq(uint256(pool.status(M1)), uint256(OGClubCreatorPool.MonthStatus.Swept));
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.NothingToSweep.selector, M1));
        pool.sweep(M1);
    }

    function test_sweep_unknownMonth() public {
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.MonthNotProposed.selector, M1));
        pool.sweep(M1);
    }

    // ────────────────────────────────────────────────────────────────────── owner cannot ──

    function test_renounceOwnershipDisabled() public {
        vm.prank(owner);
        vm.expectRevert(OGClubCreatorPool.RenounceDisabled.selector);
        pool.renounceOwnership();
        assertEq(pool.owner(), owner);
        vm.prank(stranger);
        vm.expectRevert(OGClubCreatorPool.RenounceDisabled.selector);
        pool.renounceOwnership();
    }

    function test_ownerCannotBeAPayoutWallet() public {
        bytes32 id = pool.gameId("owner-game");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.InvalidPayout.selector, owner));
        pool.listGame(id, owner);
        // Nor may a game wallet move its payout to the owner.
        vm.prank(dev1);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.InvalidPayout.selector, owner));
        pool.changePayout(G1, owner);
        // The pending owner is refused too.
        vm.prank(owner);
        pool.transferOwnership(stranger);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.InvalidPayout.selector, stranger));
        pool.listGame(id, stranger);
        vm.prank(dev1);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.InvalidPayout.selector, stranger));
        pool.changePayout(G1, stranger);
    }

    function test_claim_revertsWhenPayoutBecameOwner() public {
        // dev1 was listed before becoming owner; a claim to dev1 is refused until the game moves
        // its payout elsewhere.
        (bytes32[] memory g, uint256[] memory a) = _three();
        bytes32[] memory leaves = _propose(M1, g, a);
        vm.prank(owner);
        pool.transferOwnership(dev1);
        vm.prank(dev1);
        pool.acceptOwnership();
        skip(3 days);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.InvalidPayout.selector, dev1));
        pool.claim(M1, G1, a[0], Merkle.proof(leaves, 0));
        // Other games are unaffected, and dev1's game can claim again once it names another wallet.
        pool.claim(M1, G2, a[1], Merkle.proof(leaves, 1));
        address other = makeAddr("dev1-other");
        vm.prank(dev1);
        pool.changePayout(G1, other);
        pool.claim(M1, G1, a[0], Merkle.proof(leaves, 0));
        assertEq(og.balanceOf(other), a[0]);
        assertEq(og.balanceOf(dev1), 0, "owner got nothing");
    }

    function test_ownerHasNoWayToTakeTokens() public {
        (bytes32[] memory g, uint256[] memory a) = _three();
        _fund(1000 ether);
        _propose(M1, g, a);
        // There is no withdraw/rescue selector: an unknown call reverts.
        vm.prank(owner);
        (bool ok,) = address(pool).call(abi.encodeWithSignature("withdraw(uint256)", 1));
        assertFalse(ok);
        vm.prank(owner);
        (ok,) = address(pool).call(abi.encodeWithSignature("rescue(address,uint256)", address(og), 1));
        assertFalse(ok);
        // Sweep after the window returns to free(), never to the owner.
        skip(3 days + 90 days);
        vm.prank(owner);
        pool.sweep(M1);
        assertEq(og.balanceOf(owner), 0);
        assertEq(og.balanceOf(address(pool)), 1000 ether);
    }
}
