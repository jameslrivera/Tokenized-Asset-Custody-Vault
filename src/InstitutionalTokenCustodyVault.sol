pragma solidity 0.8.38;

import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";

contract InstitutionalTokenCustodyVault is AccessControlDefaultAdminRules {
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    bytes32 public constant POLICY_ROLE = keccak256("POLICY_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant SIGNER_ADMIN_ROLE = keccak256("SIGNER_ADMIN_ROLE");

    mapping(address => bool) public investorAllowed;
    mapping(address => mapping(address => bool)) public recipientAllowed;

    uint256 public policyEpoch = 1;

    error InvalidInvestor();
    error InvalidRecipient();

    event InvestorAllowedChanged(address indexed investor, bool previousAllowed, bool allowed);

    event PolicyEpochAdvanced(uint256 previousEpoch, uint256 newEpoch);

    event RecipientAllowedChanged (
        address indexed owner,
        address indexed recipient,
        bool previousAllowed,
        bool allowed

    );

    constructor(address initialAdmin) AccessControlDefaultAdminRules(1 days, initialAdmin) {}

    function setInvestorAllowed(address investor, bool allowed) external onlyRole(COMPLIANCE_ROLE) {
        if (investor == address(0)) revert InvalidInvestor();
        bool previousAllowed = investorAllowed[investor];
        if (previousAllowed == allowed) return;
        investorAllowed[investor] = allowed;

        uint256 previousEpoch = policyEpoch;
        policyEpoch = previousEpoch + 1;

        emit InvestorAllowedChanged(investor, previousAllowed, allowed);
        emit PolicyEpochAdvanced(previousEpoch, policyEpoch);
    }

    function setRecipientAllowed(address owner, address recipient, bool allowed)
        external
        onlyRole(COMPLIANCE_ROLE)
        {
            if (owner == address(0)) revert InvalidInvestor();

            if (recipient == address(0) || recipient == address(this)) {
                revert InvalidRecipient();
            }

            bool previousAllowed = recipientAllowed[owner][recipient];

            if (previousAllowed == allowed) return;

            recipientAllowed[owner][recipient] = allowed;

            uint256 previousEpoch = policyEpoch;
            policyEpoch = previousEpoch + 1;

            emit RecipientAllowedChanged(owner, recipient, previousAllowed, allowed);
            emit PolicyEpochAdvanced(previousEpoch, policyEpoch);
        }
}
