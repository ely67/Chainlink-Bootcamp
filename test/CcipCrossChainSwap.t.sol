// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

// Import necessary contracts and interfaces
import { Test, Vm, console } from "forge-std/Test.sol";
import { CrossChainReceiver } from "../src/CrossChainReceiver.sol";
import { SwapTestnetUSDC, IFauceteer } from "../src/SwapTestnetUSDC .sol";
import { TransferUSDC } from "../src/TransferUSDC .sol";
import { CCIPLocalSimulatorFork, Register } from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";

// Main contract for testing CCIP cross-chain swap functionality
contract CcipCrossChainSwap is Test {
    // Declare state variables
    CCIPLocalSimulatorFork public ccipLocalSimulatorFork;
    uint256 sepoliaFork;
    uint256 avalancheFujiFork;
    Register.NetworkDetails sepoliaNetworkDetails;
    Register.NetworkDetails avalancheFujiNetworkDetails;
    
    // Define contract addresses
    address cometAddress = 0xAec1F48e02Cfb822Be958B68C7957156EB3F0b6e;
    address fauceteer = 0x68793eA49297eB75DFB4610B68e076D2A5c7646C;
    address fujiUsdc = 0x5425890298aed601595a70AB815c96711a31Bc65;
    address sepoliaUsdc = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address myWallet = 0x4a0d22D63a1DAE518D3385cEEC89703a62D44BB3;

    // Declare contract instances
    CrossChainReceiver public receiver;
    TransferUSDC public sender;
    SwapTestnetUSDC public swap;

    // Setup function to initialize the test environment
    function setUp() public {
        // Fork the Avalanche Fuji and Sepolia networks
        string memory AVALANCHE_FUJI_RPC_URL = vm.envString("AVALANCHE_FUJI_RPC_URL");
        string memory ETHEREUM_SEPOLIA_RPC_URL = vm.envString("ETHEREUM_SEPOLIA_RPC_URL");
        avalancheFujiFork = vm.createSelectFork(AVALANCHE_FUJI_RPC_URL);
        sepoliaFork = vm.createFork(ETHEREUM_SEPOLIA_RPC_URL);
        
        // Initialize the CCIP local simulator
        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipLocalSimulatorFork));

        // Get network details for both chains
        avalancheFujiNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);
        vm.selectFork(sepoliaFork);
        sepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid); 

        // Deploy the sender contract on Avalanche Fuji
        vm.selectFork(avalancheFujiFork);
        vm.prank(myWallet);
        sender = new TransferUSDC(avalancheFujiNetworkDetails.routerAddress, avalancheFujiNetworkDetails.linkAddress, fujiUsdc);
        console.log("Sender contract deployed at:", address(sender));

        // Request LINK tokens for the sender contract
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(sender), 5 ether);
        vm.prank(myWallet);
        sender.allowlistDestinationChain(sepoliaNetworkDetails.chainSelector, true);

        // Deploy the receiver and swap contracts on Sepolia
        vm.selectFork(sepoliaFork);
        vm.prank(myWallet);
        swap = new SwapTestnetUSDC(sepoliaUsdc, sepoliaUsdc, fauceteer);
        vm.prank(myWallet);
        receiver = new CrossChainReceiver(sepoliaNetworkDetails.routerAddress, cometAddress, address(swap));    
        
        // Set up allowlists for the receiver contract
        vm.prank(myWallet);
        receiver.allowlistSourceChain(avalancheFujiNetworkDetails.chainSelector, true);
        vm.prank(myWallet);
        receiver.allowlistSender(address(sender), true);
    }

    // Function to estimate gas usage for the cross-chain transfer
    function estimateGas() public returns(uint64){
        vm.selectFork(avalancheFujiFork);
        uint256 amount = 1000000;
        uint64 gas = 400000;
        vm.recordLogs();
        vm.prank(myWallet);
        sender.transferUsdc(avalancheFujiNetworkDetails.chainSelector,
            address(receiver), amount, gas);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 msgExecutedSignature = keccak256(
            "MsgExecuted(bool,bytes,uint256)"
        );

        // Parse logs to find gas used
        for (uint i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == msgExecutedSignature) {
                (, , uint256 gasUsed) = abi.decode(
                    logs[i].data,
                    (bool, bytes, uint256)
                );
                console.log(
                    "Gas used:",
                     gasUsed
                );
                return uint64(gasUsed);
            }
        }
    }

    function estimateAverageGas(uint8 iterations) public returns(uint64) {
        uint256 totalGas = 0;
        for (uint8 i = 0; i < iterations; i++) {
            uint64 gasEstimate = estimateGas();
            if (gasEstimate > 0) {
                totalGas += gasEstimate;
                } else {
                console.log("Warning: Gas estimation failed for iteration", i);
            }
        }
        if (totalGas == 0) {
            revert("All gas estimations failed");
        }
        return uint64(totalGas / iterations);
    }

    // Main test function for the cross-chain swap
    function test_fork() public {
        vm.selectFork(avalancheFujiFork);
        vm.prank(myWallet);
        uint64 gasUsed = estimateAverageGas(3); // Run 3 iterations for average
        uint64 adjustedGas = gasUsed + (gasUsed * 10 / 100); // Increased buffer to 15%
        uint256 amount = 1000000;

        vm.prank(myWallet);
        sender.transferUsdc(avalancheFujiNetworkDetails.chainSelector, 
        address(receiver), amount, adjustedGas);
    
        ccipLocalSimulatorFork.switchChainAndRouteMessage(sepoliaFork);
    }
}