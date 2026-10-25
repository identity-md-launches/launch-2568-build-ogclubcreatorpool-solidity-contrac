// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OGClubCreatorPool} from "../src/OGClubCreatorPool.sol";
import {IOGClubFarmVault, OGClubFarmVaultBytecode} from "./support/OGClubFarmVaultBytecode.sol";
import {MockOG} from "./support/MockOG.sol";
import {Merkle} from "./support/Merkle.sol";

/// @notice End to end: a farm vault season lists the creator pool as one of its accounts, the vault
///         claim lands $OG in the pool as a plain transfer, and a pool month then pays the games.
///         "The vault" is the real OGClubFarmVault: its creation code copied from mainnet
///         (0x60401e748d6c3a1f2775bE9e6a41bda20eDa0B80), deployed here with a mock $OG. Its source is
///         unverified, so it is driven through the selectors its dispatcher exposes; the first test
///         proves the bytes are the live contract's.
contract OGClubCreatorPoolIntegrationTest is Test {
    uint256 internal constant START = 1_800_000_000;
    uint256 internal constant MONTH = 202_702;

    MockOG internal og;
    IOGClubFarmVault internal vault;
    OGClubCreatorPool internal pool;

    address internal owner = makeAddr("owner");
    address internal farmer1 = makeAddr("farmer1");
    address internal farmer2 = makeAddr("farmer2");
    address internal relayer = makeAddr("relayer");
    address internal dev1 = makeAddr("dev1");
    address internal dev2 = makeAddr("dev2");
    address internal dev3 = makeAddr("dev3");

    function setUp() public {
        vm.warp(START);
        og = new MockOG();
        vault = IOGClubFarmVault(OGClubFarmVaultBytecode.deploy(address(og), owner));
        pool = new OGClubCreatorPool(IERC20(address(og)), owner);
        vm.startPrank(owner);
        pool.listGame(pool.gameId("coin-dash"), dev1);
        pool.listGame(pool.gameId("rocket-run"), dev2);
        pool.listGame(pool.gameId("puzzle-pit"), dev3);
        vm.stopPrank();
        og.mint(address(vault), 10_000 ether);
    }

    function _vaultLeaf(uint256 season, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(season, account, amount))));
    }

    /// @dev The vault numbers its seasons itself: the next one is seasonCount() + 1.
    function _proposeSeason(address[] memory accounts, uint256[] memory shares, uint256 total)
        internal
        returns (uint256 season, bytes32[] memory leaves)
    {
        season = vault.seasonCount() + 1;
        leaves = new bytes32[](accounts.length);
        for (uint256 i; i < accounts.length; ++i) {
            leaves[i] = _vaultLeaf(season, accounts[i], shares[i]);
        }
        vm.prank(owner);
        assertEq(vault.proposeSeason(Merkle.root(leaves), total), season);
    }

    function test_vaultBytecodeIsTheLiveContract() public {
        address copy = OGClubFarmVaultBytecode.deploy(OGClubFarmVaultBytecode.LIVE_TOKEN, OGClubFarmVaultBytecode.LIVE_OWNER);
        assertEq(copy.code, OGClubFarmVaultBytecode.LIVE_RUNTIME, "deployed bytes differ from mainnet runtime");
        assertEq(IOGClubFarmVault(copy).token(), OGClubFarmVaultBytecode.LIVE_TOKEN);
        assertEq(IOGClubFarmVault(copy).owner(), OGClubFarmVaultBytecode.LIVE_OWNER);
        // The copy under test is the same code with the mock token.
        assertEq(vault.token(), address(og));
        assertEq(vault.owner(), owner);
        assertEq(vault.CLAIM_DELAY(), 3 days);
        assertEq(vault.CLAIM_PERIOD(), 90 days);
    }

    function test_vaultSeasonFundsPoolThenPoolPaysGames() public {
        // 1. A vault season: two farmers and the creator pool share 1,000 $OG.
        address[] memory accounts = new address[](3);
        (accounts[0], accounts[1], accounts[2]) = (farmer1, address(pool), farmer2);
        uint256[] memory shares = new uint256[](3);
        (shares[0], shares[1], shares[2]) = (300 ether, 500 ether, 200 ether);
        (uint256 season, bytes32[] memory seasonLeaves) = _proposeSeason(accounts, shares, 1000 ether);

        // The vault's own delay applies before anything lands in the pool.
        vm.expectRevert(IOGClubFarmVault.ClaimsNotOpen.selector);
        vault.claim(season, address(pool), 500 ether, Merkle.proof(seasonLeaves, 1));
        skip(3 days);

        // 2. Anyone pushes the pool's vault claim; the $OG lands in the pool as a plain transfer.
        assertEq(pool.free(), 0);
        vm.prank(relayer);
        vault.claim(season, address(pool), 500 ether, Merkle.proof(seasonLeaves, 1));
        assertTrue(vault.claimed(season, address(pool)));
        assertEq(og.balanceOf(address(pool)), 500 ether);
        assertEq(pool.free(), 500 ether, "vault payout is free until a month reserves it");
        assertEq(pool.reserved(), 0);

        // The farmers' own claims are unaffected.
        vault.claim(season, farmer1, 300 ether, Merkle.proof(seasonLeaves, 0));
        assertEq(og.balanceOf(farmer1), 300 ether);

        // 3. The owner proposes the month's list out of the vault money.
        bytes32[3] memory games = [pool.gameId("coin-dash"), pool.gameId("rocket-run"), pool.gameId("puzzle-pit")];
        uint256[3] memory amounts = [uint256(200 ether), 175 ether, 125 ether];
        bytes32[] memory monthLeaves = new bytes32[](3);
        for (uint256 i; i < 3; ++i) {
            monthLeaves[i] = pool.leaf(MONTH, games[i], amounts[i]);
        }
        vm.prank(owner);
        pool.proposeMonth(MONTH, Merkle.root(monthLeaves), 500 ether);
        assertEq(pool.free(), 0);
        assertEq(pool.reserved(), 500 ether);

        // 4. Three days later the games get paid, pushed by anyone.
        skip(3 days);
        address[3] memory devs = [dev1, dev2, dev3];
        for (uint256 i; i < 3; ++i) {
            vm.prank(relayer);
            pool.claim(MONTH, games[i], amounts[i], Merkle.proof(monthLeaves, i));
            assertEq(og.balanceOf(devs[i]), amounts[i]);
        }
        assertEq(og.balanceOf(address(pool)), 0);
        assertEq(pool.reserved(), 0);
        assertEq(og.balanceOf(relayer), 0, "relayer gets nothing");
        assertEq(og.balanceOf(owner), 0, "owner gets nothing");
    }

    function test_monthCannotBeProposedBeforeVaultPays() public {
        address[] memory accounts = new address[](1);
        accounts[0] = address(pool);
        uint256[] memory shares = new uint256[](1);
        shares[0] = 500 ether;
        (uint256 season,) = _proposeSeason(accounts, shares, 500 ether);

        // Season proposed but not yet claimed into the pool: nothing is free.
        bytes32 someRoot = pool.leaf(MONTH, pool.gameId("coin-dash"), 1 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OGClubCreatorPool.InsufficientFree.selector, 1 ether, 0));
        pool.proposeMonth(MONTH, someRoot, 1 ether);

        skip(3 days);
        vault.claim(season, address(pool), 500 ether, new bytes32[](0));
        vm.prank(owner);
        pool.proposeMonth(MONTH, someRoot, 1 ether);
        assertEq(pool.free(), 499 ether);
    }

    function test_vaultPayoutsAcrossSeasonsAccumulateAsFree() public {
        address[] memory accounts = new address[](1);
        accounts[0] = address(pool);
        uint256[] memory shares = new uint256[](1);
        shares[0] = 100 ether;
        for (uint256 s = 1; s <= 3; ++s) {
            (uint256 season,) = _proposeSeason(accounts, shares, 100 ether);
            assertEq(season, s);
            skip(3 days);
            vault.claim(season, address(pool), 100 ether, new bytes32[](0));
            skip(vault.PROPOSAL_INTERVAL()); // the vault spaces its proposals
        }
        assertEq(pool.free(), 300 ether);
    }
}
