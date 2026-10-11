// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {UnlkHook} from "./UnlkHook.sol";

/// @notice Deterministic deployment helper. Deployment is a separate, explicitly authorized release step.
contract HookDeployer {
    event HookCreated(address indexed hook, bytes32 salt);

    function initCodeHash(UnlkHook.Config calldata config) external pure returns (bytes32) {
        return keccak256(bytes.concat(type(UnlkHook).creationCode, abi.encode(config)));
    }

    function predict(bytes32 salt, bytes32 codeHash) public view returns (address) {
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, codeHash))))
            );
    }

    function deploy(bytes32 salt, UnlkHook.Config calldata config) external returns (UnlkHook hook) {
        hook = new UnlkHook{salt: salt}(config);
        emit HookCreated(address(hook), salt);
    }
}
