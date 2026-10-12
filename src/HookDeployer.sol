// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {UnlkHook} from "./UnlkHook.sol";

/// @notice Deterministic deployment helper. Deployment is a separate, explicitly authorized release step.
contract HookDeployer {
    event HookCreated(address indexed hook, bytes32 salt);

    /// @notice Creation code with the flat constructor words appended, exactly as the IMD manifest encodes
    /// `hook.constructorArgs` and as `LaunchFactory.predictHook`/`launch` consume it.
    function initCode(UnlkHook.Config calldata config) public pure returns (bytes memory) {
        return bytes.concat(
            type(UnlkHook).creationCode,
            abi.encode(
                config.manager,
                config.token,
                config.launchFactory,
                config.payer,
                config.router,
                config.rewards,
                config.oracle,
                config.tickSpacing
            )
        );
    }

    function initCodeHash(UnlkHook.Config calldata config) external pure returns (bytes32) {
        return keccak256(initCode(config));
    }

    function predict(bytes32 salt, bytes32 codeHash) public view returns (address) {
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, codeHash))))
            );
    }

    function deploy(bytes32 salt, UnlkHook.Config calldata config) external returns (UnlkHook hook) {
        hook = new UnlkHook{salt: salt}(
            config.manager,
            config.token,
            config.launchFactory,
            config.payer,
            config.router,
            config.rewards,
            config.oracle,
            config.tickSpacing
        );
        emit HookCreated(address(hook), salt);
    }
}
