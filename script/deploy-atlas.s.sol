//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { Atlas } from "../src/atlas/core/Atlas.sol";
import { FactoryLib } from "../src/atlas/core/FactoryLib.sol";
import { AtlasVerification } from "../src/atlas/core/AtlasVerification.sol";
import { Simulator } from "../src/atlas/helpers/Simulator.sol";
import { Sorter } from "../src/atlas/helpers/Sorter.sol";
import { ExecutionEnvironment } from "../src/atlas/common/ExecutionEnvironment.sol";
import { ShMonad } from "fastlane-contracts/shmonad/ShMonad.sol";
import { JsonHelper } from "./utils/JsonHelper.sol";
import { AddressHub } from "../src/common/AddressHub.sol";
import { Directory } from "../src/common/Directory.sol";

contract DeployAtlasScript is Script {
    using JsonHelper for VmSafe;

    // Atlas Contracts
    Atlas public atlas;
    AtlasVerification public atlasVerification;
    Simulator public simulator;
    Sorter public sorter;

    // ShMonad Proxy on Monad Testnet - NOTE: Double check this is the correct address
    ShMonad public shMonad = ShMonad(payable(0x3a98250F98Dd388C211206983453837C8365BDc1));

    // Atlas Deployment Parameters
    uint48 ESCROW_DURATION = 240; // 0.5s blocks = 120 seconds = 2 mins
    uint256 ATLAS_SURCHARGE_RATE = 2500; // 25%

    // Atlas uses Policy ID 14 in ShMonad on Monad Testnet
    uint64 ATLAS_POLICY_ID = 14;

    // Track the most recently deployed Atlas address here - to be removed as policy agent when a new Atlas is deployed
    address PREV_ATLAS = 0x9958Ab9f64EF51194C5378a336D2A0b0A620D31c;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("GOV_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address addressHub = vm.envAddress("ADDRESS_HUB");

        // Get the AddressHub instance
        AddressHub hub = AddressHub(addressHub);

        // address taskManagerAddress = hub.getAddressFromPointer(Directory._TASK_MANAGER);
        // require(taskManagerAddress != address(0), "TaskManager not properly set in AddressHub");

        console.log("Starting Atlas deployment...");
        console.log("\n");
        console.log("Deployer address: \t\t", deployer);
        console.log("ShMonad address: \t\t", address(shMonad));
        console.log("Network: \t\t\t", block.chainid);

        // Computes the addresses at which AtlasVerification will be deployed
        address expectedAtlasAddr = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 2);
        address expectedAtlasVerificationAddr = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 3);
        address expectedSimulatorAddr = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 4);

        vm.startBroadcast(deployerPrivateKey);

        // Create ShMonad policy for Atlas - Disabled as Atlas uses Policy ID 14 on Monad Testnet
        // (uint64 atlasPolicyId,) = shMonad.createPolicy(ESCROW_DURATION);
        // NOTE: If this ^ is reenabled, remember to increment nonces in expected addr calcs above

        // Deploy the ExecutionEnvironment template, passing in the predicted Atlas address
        ExecutionEnvironment execEnvTemplate = new ExecutionEnvironment(expectedAtlasAddr);

        // Deploy FactoryLib using precompile from Atlas v1.3 - avoids adjusting Mimic assembly
        FactoryLib factoryLib = FactoryLib(
            deployCode("src/atlas/precompiles/FactoryLib.sol/FactoryLib.json", abi.encode(address(execEnvTemplate)))
        );

        // Deploy Atlas
        atlas = new Atlas({
            atlasSurchargeRate: ATLAS_SURCHARGE_RATE,
            verification: expectedAtlasVerificationAddr,
            simulator: expectedSimulatorAddr,
            factoryLib: address(factoryLib),
            initialSurchargeRecipient: deployer,
            l2GasCalculator: address(0),
            // taskManager: taskManagerAddress,
            shMonad: address(shMonad),
            shMonadPolicyID: ATLAS_POLICY_ID
        });

        // Deploy AtlasVerification
        atlasVerification = new AtlasVerification({ atlas: expectedAtlasAddr, l2GasCalculator: address(0) });

        // Deploy Simulator and set its Atlas address
        simulator = new Simulator();
        simulator.setAtlas(address(atlas));

        // Deploy Sorter
        sorter = new Sorter(address(atlas));

        // Remove previous Atlas deployment (if any) as policy agent
        if (PREV_ATLAS != address(0)) {
            // NOTE: Intentionally not removing prev Atlas as we want a parallel v1.6 and v1.6.1
            // shMonad.removePolicyAgent(ATLAS_POLICY_ID, PREV_ATLAS);
            console.log("Intentionally not removing prev Atlas as policy agent.");
        }

        // Add the Atlas contract as a policy agent for its ShMonad bond policy
        shMonad.addPolicyAgent(ATLAS_POLICY_ID, address(atlas));

        vm.stopBroadcast();

        // Check for any misconfigurations in the deployed contracts
        bool error = false;

        // Check Atlas address set correctly everywhere
        if (address(atlas) != atlasVerification.ATLAS()) {
            console.log("ERROR: Atlas address not set correctly in AtlasVerification");
            error = true;
        }
        if (address(atlas) != simulator.atlas()) {
            console.log("ERROR: Atlas address not set correctly in Simulator");
            error = true;
        }
        if (address(atlas) != address(sorter.ATLAS())) {
            console.log("ERROR: Atlas address not set correctly in Sorter");
            error = true;
        }
        if (address(atlas) == address(0)) {
            console.log("ERROR: Atlas deployment address is 0x0");
            error = true;
        }
        // Check AtlasVerification address set correctly everywhere
        if (address(atlasVerification) != address(atlas.VERIFICATION())) {
            console.log("ERROR: AtlasVerification address not set correctly in Atlas");
            error = true;
        }
        if (address(atlasVerification) != address(sorter.VERIFICATION())) {
            console.log("ERROR: AtlasVerification address not set correctly in Sorter");
            error = true;
        }
        if (address(atlasVerification) == address(0)) {
            console.log("ERROR: AtlasVerification deployment address is 0x0");
            error = true;
        }
        // Check Simulator address set correctly in Atlas
        if (address(simulator) != atlas.SIMULATOR()) {
            console.log("ERROR: Simulator address not set correctly in Atlas");
            error = true;
        }
        if (address(simulator) == address(0)) {
            console.log("ERROR: Simulator deployment address is 0x0");
            error = true;
        }
        // Check Sorter address set correctly everywhere
        if (address(sorter) == address(0)) {
            console.log("ERROR: Sorter deployment address is 0x0");
            error = true;
        }
        // Check FactoryLib address set correctly in Atlas
        if (address(factoryLib) != atlas.FACTORY_LIB()) {
            console.log("ERROR: FactoryLib address not set correctly in Atlas");
            error = true;
        }
        // Check ExecutionEnvironment address set correctly in FactoryLib
        if (address(execEnvTemplate) != factoryLib.EXECUTION_ENV_TEMPLATE()) {
            console.log("ERROR: ExecutionEnvironment address not set correctly in FactoryLib");
            error = true;
        }
        // Check ShMonad address set correctly in Atlas
        if (address(shMonad) != address(atlas.SHMONAD())) {
            console.log("ERROR: ShMonad address not set correctly in Atlas");
            error = true;
        }
        // Check Atlas Policy ID set correctly in Atlas
        if (atlas.POLICY_ID() != ATLAS_POLICY_ID) {
            console.log("ERROR: Atlas Policy ID not set correctly in Atlas");
            error = true;
        }

        if (error) {
            console.log("ERROR: One or more addresses are incorrect. Exiting.");
            return;
        }

        VmSafe(vm).updateLastDeployBlock({ isMainnet: false, blockNumber: block.number });

        console.log("\n");
        console.log("------------------------------------------------------------------------");
        console.log("| Contract              | Address                                      |");
        console.log("------------------------------------------------------------------------");
        console.log("| Atlas                 | ", address(atlas), " |");
        console.log("| AtlasVerification     | ", address(atlasVerification), " |");
        console.log("| Simulator             | ", address(simulator), " |");
        console.log("| Sorter                | ", address(sorter), " |");
        console.log("------------------------------------------------------------------------");

        console.log("\n");
        console.log("------------------------------------------------------------------------");
        console.log("| Variable              | Value                                        |");
        console.log("------------------------------------------------------------------------");
        console.log("| Atlas Owner:          |", deployer, "  |");
        console.log("| Atlas Policy ID:      |", ATLAS_POLICY_ID, "                                          |");
        console.log("------------------------------------------------------------------------");
        console.log("\n");

        // ---------------------------------------------------------
        //  Contract Verification
        // ---------------------------------------------------------

        // Atlas.sol
        bytes memory atlasEncodedArgs = abi.encode(
            ATLAS_SURCHARGE_RATE,
            expectedAtlasVerificationAddr,
            expectedSimulatorAddr,
            address(factoryLib),
            deployer,
            address(0), // l2GasCalculator
            // taskManagerAddress,
            address(shMonad),
            ATLAS_POLICY_ID
        );
        string memory verifyStr = string.concat(
            "forge verify-contract ",
            vm.toString(address(atlas)),
            " src/atlas/core/Atlas.sol:Atlas ",
            "--chain 10143 --verifier sourcify --verifier-url https://sourcify-api-monad.blockvision.org --constructor-args ",
            vm.toString(atlasEncodedArgs),
            " --rpc-url https://testnet-rpc.monad.xyz"
        );
        console.log("Verify Atlas with:");
        console.log(verifyStr);
        console.log("\n");

        // AtlasVerification.sol
        bytes memory atlasVerificationEncodedArgs = abi.encode(expectedAtlasAddr, address(0)); // l2GasCalculator
        string memory verifyAtlasVerificationStr = string.concat(
            "forge verify-contract ",
            vm.toString(address(atlasVerification)),
            " src/atlas/core/AtlasVerification.sol:AtlasVerification ",
            "--chain 10143 --verifier sourcify --verifier-url https://sourcify-api-monad.blockvision.org --constructor-args ",
            vm.toString(atlasVerificationEncodedArgs),
            " --rpc-url https://testnet-rpc.monad.xyz"
        );
        console.log("Verify AtlasVerification with:");
        console.log(verifyAtlasVerificationStr);
        console.log("\n");

        // Simulator.sol
        bytes memory simulatorEncodedArgs = abi.encode(address(atlas));
        string memory verifySimulatorStr = string.concat(
            "forge verify-contract ",
            vm.toString(address(simulator)),
            " src/atlas/helpers/Simulator.sol:Simulator ",
            "--chain 10143 --verifier sourcify --verifier-url https://sourcify-api-monad.blockvision.org --constructor-args ",
            vm.toString(simulatorEncodedArgs),
            " --rpc-url https://testnet-rpc.monad.xyz"
        );
        console.log("Verify Simulator with:");
        console.log(verifySimulatorStr);
        console.log("\n");

        // Sorter.sol
        bytes memory sorterEncodedArgs = abi.encode(address(atlas));
        string memory verifySorterStr = string.concat(
            "forge verify-contract ",
            vm.toString(address(sorter)),
            " src/atlas/helpers/Sorter.sol:Sorter ",
            "--chain 10143 --verifier sourcify --verifier-url https://sourcify-api-monad.blockvision.org --constructor-args ",
            vm.toString(sorterEncodedArgs),
            " --rpc-url https://testnet-rpc.monad.xyz"
        );
        console.log("Verify Sorter with:");
        console.log(verifySorterStr);
        console.log("\n");
    }
}
