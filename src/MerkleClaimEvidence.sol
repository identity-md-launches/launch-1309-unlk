// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IClaimEvidence, IMerkleDistributor} from "./interfaces/IIntegration.sol";

/// @notice Immutable adapter from the verified IMD `MerkleDistributor` to the hook's cumulative-claim view.
/// @dev The distributor stores only `claimed[round][account] == true`, never an amount. The amount lives in the
/// leaf `keccak256(bytes.concat(keccak256(abi.encode(account, amount))))` committed by the round's root, and
/// `MerkleDistributor.claim` transfers exactly that amount to exactly that account. So a claim is proven here by
/// (1) the distributor's own `claimed` flag for the round and account and (2) a proof of the leaf against the
/// round's root read from the distributor. Nothing is caller-selected: a wrong amount fails the proof, a wrong
/// account fails the flag, a round can be attested once per account, and the credit can only go to `account`.
/// The adapter never touches the distributor's claim path; native claims need no interaction with it.
///
/// Assumption (documented, not enforceable on chain): IMD's tree builder emits at most one leaf per account per
/// round, as OpenZeppelin's StandardMerkleTree flow does. A tree with two leaves for one account would let the
/// larger leaf be attested after the smaller was claimed; the over-credit is bounded by IMD's own allocation.
contract MerkleClaimEvidence is IClaimEvidence {
    IMerkleDistributor public immutable merkleDistributor;
    address public immutable token;

    mapping(address account => uint256) public claimed;
    mapping(uint256 round => mapping(address account => bool)) public attested;

    error InvalidConfig();
    error NotClaimed();
    error AlreadyAttested();
    error InvalidProof();

    event Attested(uint256 indexed round, address indexed account, uint256 amount);

    /// @param distributor_ The distributor the factory creates for this launch, predicted or already deployed.
    /// @param token_ The launched token, predicted with `LaunchFactory.predictToken` or already deployed.
    constructor(IMerkleDistributor distributor_, address token_) {
        if (address(distributor_) == address(0) || token_ == address(0)) revert InvalidConfig();
        merkleDistributor = distributor_;
        token = token_;
    }

    function distributor() external view returns (address) {
        return address(merkleDistributor);
    }

    /// @notice Records one actual native claim. Anyone may submit it; the credit belongs to `account`.
    function attest(uint256 round, address account, uint256 amount, bytes32[] calldata proof)
        external
        returns (uint256)
    {
        if (attested[round][account]) revert AlreadyAttested();
        if (!merkleDistributor.claimed(round, account)) revert NotClaimed();
        bytes32 root = merkleDistributor.roundOf(round).root;
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
        if (!MerkleProof.verifyCalldata(proof, root, leaf)) revert InvalidProof();
        attested[round][account] = true;
        claimed[account] += amount;
        emit Attested(round, account, amount);
        return amount;
    }
}
