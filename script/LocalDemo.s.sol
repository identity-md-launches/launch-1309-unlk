// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {SystemFixture} from "../test/fixtures/SystemFixture.sol";

/// @notice LOCAL simulation harness. It is not a contract intended for deployment.
contract LocalSystem is SystemFixture {
    event LocalSystemCreated(
        address manager, address token, address hook, address router, address factory, address oracle
    );
    function setUp() public override {}

    function initializeLocal() external {
        require(block.chainid == 31337, "local chain only");
        _deploy(false);
        _launchTokenOnly(OPENING_TICK);
        _localQuoteDepth(10000 ether);
        emit LocalSystemCreated(
            address(manager),
            address(token),
            address(hook),
            address(router),
            address(factory),
            address(oracle)
        );
    }

    function deployedHook() external view returns (address) {
        return address(hook);
    }
}

/// @notice In-process LOCAL simulation only. No RPC, keys, broadcasts or public-chain transactions.
/// The large helper embeds all fixture creation code; use --disable-code-size-limit for this simulation.
contract LocalDemo {
    function run() external returns (address hook) {
        require(block.chainid == 31337, "local chain only");
        LocalSystem local = new LocalSystem();
        local.initializeLocal();
        return local.deployedHook();
    }
}
