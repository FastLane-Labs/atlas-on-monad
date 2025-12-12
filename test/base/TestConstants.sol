// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

// For any shared test constants (not specific to a protocol's setup)
contract TestConstants {
    // Monad Testnet Constants
    uint256 internal constant BLOCK_PIN_DURATION = 80_000; // reduced to avoid rpc lookup issues

    address internal constant MAINNET_SHMONAD_IMPLEMENTATION = 0x5B6af4c2584952d45153e3B78638764DDb7b5941;
    address internal constant MAINNET_SHMONAD_PROXY = 0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c;
    address internal constant MAINNET_SHMONAD_PROXY_ADMIN = 0x00b16590295092f12F4cec655296B6129C49489C;
    address internal constant MAINNET_SHMONAD_PROXY_ADMIN_OWNER = 0x48a3267BCc4Cf230e9Bc4cae0c11EEbDb9a6A687;
}
