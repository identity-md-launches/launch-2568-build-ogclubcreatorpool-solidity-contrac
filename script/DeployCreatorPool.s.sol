// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OGClubCreatorPool} from "../src/OGClubCreatorPool.sol";

/// @title Mainnet deployment of OGClubCreatorPool
/// @notice Deploys the pool against the real $OG token with the launch owner and lists no games.
///
///   OG_TOKEN=0x... OWNER=0x... forge script script/DeployCreatorPool.s.sol \
///       --rpc-url $RPC --account <keystore> --broadcast
///
/// Prints the pool address and the ABI-encoded constructor arguments for explorer verification:
///
///   forge verify-contract <pool> src/OGClubCreatorPool.sol:OGClubCreatorPool \
///       --chain 1 --constructor-args <printed bytes>
contract DeployCreatorPool is Script {
    /// @notice Deploys one pool. Pure function of its arguments so tests can call it directly.
    function deploy(IERC20 token, address owner) public returns (OGClubCreatorPool pool) {
        pool = new OGClubCreatorPool(token, owner);
        console.log("OGClubCreatorPool:", address(pool));
        console.log("  token:", address(token));
        console.log("  owner:", owner);
        console.log("  constructor args (abi-encoded, for forge verify-contract --constructor-args):");
        console.logBytes(abi.encode(address(token), owner));
    }

    /// @notice Reads OG_TOKEN and OWNER from the environment and broadcasts.
    function run() external returns (OGClubCreatorPool pool) {
        IERC20 token = IERC20(vm.envAddress("OG_TOKEN"));
        address owner = vm.envAddress("OWNER");
        vm.startBroadcast();
        pool = deploy(token, owner);
        vm.stopBroadcast();
    }
}
