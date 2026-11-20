// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {MockToken} from "../src/origin/MockToken.sol";
import {ConstantProductPool} from "../src/origin/ConstantProductPool.sol";

/// @notice Opens a transient cross-pool gap by swapping into pool A. The reactive contract
///         sees the resulting Sync log and fires; this is the origin event of the demo loop.
contract Shock is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_KEY");
        uint256 amount = vm.envOr("SHOCK_AMOUNT", uint256(20_000e18));
        string memory oj = vm.readFile("deployments/origin.json");
        MockToken token1 = MockToken(vm.parseJsonAddress(oj, ".token1"));
        ConstantProductPool poolA = ConstantProductPool(vm.parseJsonAddress(oj, ".poolA"));

        vm.startBroadcast(pk);
        token1.mint(vm.addr(pk), amount);
        token1.approve(address(poolA), type(uint256).max);
        poolA.swap(amount, false, 0, vm.addr(pk)); // token1 -> token0, raises A price
        vm.stopBroadcast();
    }
}
