// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/TokenVestingVault.sol";

contract DeployTokenVestingVault is Script {
    function run() external returns (TokenVestingVault vault) {
        vm.startBroadcast();
        vault = new TokenVestingVault();
        vm.stopBroadcast();
    }
}
