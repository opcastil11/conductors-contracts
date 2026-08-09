// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Minimal allowlist consulted at the A→B crossing. See {KycRegistry}.
interface IKycRegistry {
    function isApproved(address account) external view returns (bool);
}

/**
 * @title KycRegistry
 * @notice The gate that makes the A market permissionless while keeping Product B inside a
 *         regulated perimeter (docs/TOKENOMICS-V2.md §7.1).
 *
 * The design decision this contract encodes: Product A is a platform token and trades freely on
 * its curve/AMM with no allowlist anywhere. The instrument that actually distributes cash flow
 * is B, and the ONLY way to reach B is {AgentController.convert} — so the whole compliance
 * burden sits on that single crossing, which is what DobProtocol's own KYC/compliance stack
 * already covers for B. A never carries it.
 *
 * `attestor` is the address DobProtocol (or its delegate) uses to mirror an off-chain KYC pass
 * on-chain. It can approve and revoke, and it can do NOTHING else — this contract holds no
 * funds and controls no token.
 *
 * Known consequence, accepted (§3.3): the arbitrage that enforces `P_A ≥ P_B` can only be run by
 * addresses this registry approves. For everyone else A floats with no floor. That is the price
 * of resolving the legal question at the crossing, and it is a deliberate trade, not an
 * oversight.
 */
contract KycRegistry is Ownable, IKycRegistry {
    /// @notice The address allowed to mirror off-chain KYC results on-chain.
    address public attestor;

    mapping(address => bool) private _approved;

    event AttestorUpdated(address indexed attestor);
    event ApprovalSet(address indexed account, bool approved);

    modifier onlyAttestor() {
        require(msg.sender == attestor || msg.sender == owner(), "not attestor");
        _;
    }

    constructor(address _owner, address _attestor) Ownable(_owner) {
        require(_attestor != address(0), "zero attestor");
        attestor = _attestor;
        emit AttestorUpdated(_attestor);
    }

    function setAttestor(address _attestor) external onlyOwner {
        require(_attestor != address(0), "zero attestor");
        attestor = _attestor;
        emit AttestorUpdated(_attestor);
    }

    function setApproved(address account, bool approved) public onlyAttestor {
        _approved[account] = approved;
        emit ApprovalSet(account, approved);
    }

    function setApprovedBatch(address[] calldata accounts, bool approved) external onlyAttestor {
        for (uint256 i = 0; i < accounts.length; i++) setApproved(accounts[i], approved);
    }

    function isApproved(address account) external view returns (bool) {
        return _approved[account];
    }
}
