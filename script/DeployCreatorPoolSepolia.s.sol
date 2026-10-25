// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OGClubCreatorPool} from "../src/OGClubCreatorPool.sol";
import {MockOG} from "../test/support/MockOG.sol";

/// @title Sepolia rehearsal of OGClubCreatorPool
/// @notice Deploys a mock $OG, the pool, and lists test games from a JSON list of
///         `[{"kitId": "coin-dash", "payout": "0x..."}, ...]` (see script/config/sepolia-games.example.json).
///
///   GAMES_JSON="$(cat script/config/sepolia-games.json)" OWNER=0x... \
///       forge script script/DeployCreatorPoolSepolia.s.sol --rpc-url $SEPOLIA_RPC --account <keystore> --broadcast
///
/// The broadcaster owns the pool while the games are listed. When OWNER differs from the broadcaster
/// the script starts an Ownable2Step handover; OWNER must call acceptOwnership(). OWNER defaults to
/// the broadcaster. The mock mints MOCK_SUPPLY to the broadcaster, which can then fund() the pool.
contract DeployCreatorPoolSepolia is Script {
    /// @dev Field order must stay alphabetical: vm.parseJson encodes object keys sorted by name.
    struct TestGame {
        string kitId;
        address payout;
    }

    uint256 public constant MOCK_SUPPLY = 1_000_000 ether;

    struct Deployment {
        MockOG og;
        OGClubCreatorPool pool;
        bytes32[] gameIds;
    }

    /// @notice Deploys and lists games. `lister` must be the account sending these calls (the
    ///         broadcaster in a script run, the caller contract in a test); it is the pool's owner
    ///         until `finalOwner` accepts the handover.
    function deploy(address lister, address finalOwner, string memory gamesJson) public returns (Deployment memory d) {
        TestGame[] memory gamesList = parseGames(gamesJson);

        d.og = new MockOG();
        d.og.mint(lister, MOCK_SUPPLY);
        d.pool = new OGClubCreatorPool(IERC20(address(d.og)), lister);

        d.gameIds = new bytes32[](gamesList.length);
        for (uint256 i; i < gamesList.length; ++i) {
            bytes32 id = d.pool.gameId(gamesList[i].kitId);
            d.pool.listGame(id, gamesList[i].payout);
            d.gameIds[i] = id;
            console.log("  listed", gamesList[i].kitId, "->", gamesList[i].payout);
            console.logBytes32(id);
        }

        if (finalOwner != lister) {
            d.pool.transferOwnership(finalOwner);
            console.log("  ownership offered to", finalOwner, "(must call acceptOwnership)");
        }

        console.log("MockOG:", address(d.og));
        console.log("OGClubCreatorPool:", address(d.pool));
        console.log("  constructor args (abi-encoded):");
        console.logBytes(abi.encode(address(d.og), lister));
    }

    /// @notice Parses `[{"kitId": "...", "payout": "0x..."}, ...]`.
    function parseGames(string memory gamesJson) public pure returns (TestGame[] memory gamesList) {
        gamesList = abi.decode(vm.parseJson(gamesJson), (TestGame[]));
    }

    function run() external returns (Deployment memory d) {
        string memory gamesJson = vm.envString("GAMES_JSON");
        address finalOwner = vm.envOr("OWNER", msg.sender);
        vm.startBroadcast();
        d = deploy(msg.sender, finalOwner, gamesJson);
        vm.stopBroadcast();
    }
}
