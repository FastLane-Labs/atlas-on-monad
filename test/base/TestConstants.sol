// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// For any shared test constants (not specific to a protocol's setup)
contract TestConstants {
    // Monad Testnet Constants
    uint256 internal constant BLOCK_PIN_DURATION = 80_000; // reduced to avoid rpc lookup issues

    // AddressHub
    address internal constant TESTNET_ADDRESS_HUB = 0xC9f0cDE8316AbC5Efc8C3f5A6b571e815C021B51;

    // SHMONAD
    address internal constant TESTNET_SHMONAD_PROXY_ADMIN = 0x0f8361B0C2F9C23e6e9BBA54FF01084596b38AcA;
    address internal constant TESTNET_FASTLANE_DEPLOYER = 0x48a3267BCc4Cf230e9Bc4cae0c11EEbDb9a6A687; // fastlane

    address internal constant MAINNET_SHMONAD_IMPLEMENTATION = 0x5B6af4c2584952d45153e3B78638764DDb7b5941;
    address internal constant MAINNET_SHMONAD_PROXY = 0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c;
    address internal constant MAINNET_SHMONAD_PROXY_ADMIN = 0x00b16590295092f12F4cec655296B6129C49489C;
    address internal constant MAINNET_SHMONAD_PROXY_ADMIN_OWNER = 0x48a3267BCc4Cf230e9Bc4cae0c11EEbDb9a6A687;

    // Networks
    string internal constant MAINNET_RPC_URL = "https://rpc1.monad.xyz";

}
