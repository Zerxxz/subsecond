// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {MockToken} from "../src/origin/MockToken.sol";
import {ConstantProductPool} from "../src/origin/ConstantProductPool.sol";
import {ArbExecutor} from "../src/destination/ArbExecutor.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";

/// @notice Deploys the Base Sepolia side: two assets, two AMM pools, and the callback executor.
///         The executor's immutable callbackSender is bound to PREDICTED_REACTIVE (the address
///         the Lasna reactive contract will occupy), so deploy the reactive side second.
contract DeployOrigin is Script {
    address payable constant BASE_SEPOLIA_PROXY = payable(0x476F44b11F5C942c58f4c8E3d0300E5710743585);

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_KEY");
        address predictedReactive = vm.envAddress("PREDICTED_REACTIVE");
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);

        MockToken token0 = new MockToken("Subsecond WETH", "sWETH", 18);
        MockToken token1 = new MockToken("Subsecond USDC", "sUSDC", 18);
        ConstantProductPool poolA = new ConstantProductPool(token0, token1);
        ConstantProductPool poolB = new ConstantProductPool(token0, token1);

        token0.mint(deployer, 200e18);
        token1.mint(deployer, 600_000e18);

        token0.transfer(address(poolA), 100e18);
        token1.transfer(address(poolA), 200_000e18);
        poolA.provision(100e18, 200_000e18);

        token0.transfer(address(poolB), 100e18);
        token1.transfer(address(poolB), 200_000e18);
        poolB.provision(100e18, 200_000e18);

        ArbExecutor executor = new ArbExecutor(IPayable(BASE_SEPOLIA_PROXY), predictedReactive, poolA, poolB);
        token1.mint(address(executor), 200_000e18); // arb input inventory

        vm.stopBroadcast();

        string memory j = vm.serializeAddress("origin", "token0", address(token0));
        j = vm.serializeAddress("origin", "token1", address(token1));
        j = vm.serializeAddress("origin", "poolA", address(poolA));
        j = vm.serializeAddress("origin", "poolB", address(poolB));
        j = vm.serializeAddress("origin", "executor", address(executor));
        j = vm.serializeAddress("origin", "deployer", deployer);
        j = vm.serializeUint("origin", "chainId", block.chainid);
        vm.writeJson(j, "deployments/origin.json");
    }
}
