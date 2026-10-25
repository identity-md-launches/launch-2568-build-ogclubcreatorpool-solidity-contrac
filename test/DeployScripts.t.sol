// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OGClubCreatorPool} from "../src/OGClubCreatorPool.sol";
import {DeployCreatorPool} from "../script/DeployCreatorPool.s.sol";
import {DeployCreatorPoolSepolia} from "../script/DeployCreatorPoolSepolia.s.sol";
import {MockOG} from "./support/MockOG.sol";

contract DeployScriptsTest is Test {
    address internal owner = makeAddr("owner");
    address internal dev1 = makeAddr("dev1");
    address internal dev2 = makeAddr("dev2");

    function test_mainnetScript_deploysWithTokenAndOwnerAndNoGames() public {
        MockOG og = new MockOG();
        DeployCreatorPool script = new DeployCreatorPool();
        OGClubCreatorPool pool = script.deploy(IERC20(address(og)), owner);
        assertEq(address(pool.token()), address(og));
        assertEq(pool.owner(), owner);
        assertEq(pool.pendingOwner(), address(0));
        (address payout, bool listed) = pool.games(pool.gameId("coin-dash"));
        assertEq(payout, address(0));
        assertFalse(listed);
    }

    function test_mainnetScript_rejectsZeroToken() public {
        DeployCreatorPool script = new DeployCreatorPool();
        vm.expectRevert(OGClubCreatorPool.ZeroAddress.selector);
        script.deploy(IERC20(address(0)), owner);
    }

    function _json() internal view returns (string memory) {
        return string.concat(
            '[{"kitId": "coin-dash", "payout": "',
            vm.toString(dev1),
            '"}, {"kitId": "rocket-run", "payout": "',
            vm.toString(dev2),
            '"}]'
        );
    }

    function test_sepoliaScript_parsesGames() public {
        DeployCreatorPoolSepolia script = new DeployCreatorPoolSepolia();
        DeployCreatorPoolSepolia.TestGame[] memory gamesList = script.parseGames(_json());
        assertEq(gamesList.length, 2);
        assertEq(gamesList[0].kitId, "coin-dash");
        assertEq(gamesList[0].payout, dev1);
        assertEq(gamesList[1].kitId, "rocket-run");
        assertEq(gamesList[1].payout, dev2);
    }

    function test_sepoliaScript_deploysMockListsGamesAndHandsOver() public {
        DeployCreatorPoolSepolia script = new DeployCreatorPoolSepolia();
        // The script contract sends the listing calls when called directly, so it is the lister.
        DeployCreatorPoolSepolia.Deployment memory d = script.deploy(address(script), owner, _json());

        assertEq(address(d.pool.token()), address(d.og));
        assertEq(d.og.balanceOf(address(script)), script.MOCK_SUPPLY());
        assertEq(d.gameIds.length, 2);
        assertEq(d.gameIds[0], d.pool.gameId("coin-dash"));
        (address payout, bool listed) = d.pool.games(d.gameIds[0]);
        assertEq(payout, dev1);
        assertTrue(listed);
        (payout, listed) = d.pool.games(d.gameIds[1]);
        assertEq(payout, dev2);
        assertTrue(listed);

        // Two-step handover started, not finished.
        assertEq(d.pool.owner(), address(script));
        assertEq(d.pool.pendingOwner(), owner);
        vm.prank(owner);
        d.pool.acceptOwnership();
        assertEq(d.pool.owner(), owner);
    }

    function test_sepoliaScript_sameOwnerSkipsHandover() public {
        DeployCreatorPoolSepolia script = new DeployCreatorPoolSepolia();
        DeployCreatorPoolSepolia.Deployment memory d = script.deploy(address(script), address(script), _json());
        assertEq(d.pool.owner(), address(script));
        assertEq(d.pool.pendingOwner(), address(0));
    }

    function test_sepoliaScript_emptyListIsFine() public {
        DeployCreatorPoolSepolia script = new DeployCreatorPoolSepolia();
        DeployCreatorPoolSepolia.Deployment memory d = script.deploy(address(script), owner, "[]");
        assertEq(d.gameIds.length, 0);
    }

    function test_sepoliaScript_rejectsBadPayout() public {
        DeployCreatorPoolSepolia script = new DeployCreatorPoolSepolia();
        string memory bad = '[{"kitId": "coin-dash", "payout": "0x0000000000000000000000000000000000000000"}]';
        vm.expectRevert(OGClubCreatorPool.ZeroAddress.selector);
        script.deploy(address(script), owner, bad);
    }
}
