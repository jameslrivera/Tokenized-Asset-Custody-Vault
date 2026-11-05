pragma solidity 0.8.38;

import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";



contract InstitutionalTokenCustodyVault is AccessControlDefaultAdminRules, Pausable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    bytes32 public constant POLICY_ROLE = keccak256("POLICY_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant SIGNER_ADMIN_ROLE = keccak256("SIGNER_ADMIN_ROLE");

    struct TokenPolicy {
        bool depositsEnabled;
        bool withdrawalsEnabled;
        uint256 maxPerWithdrawal;
        uint256 maxPerOwnerDay;
        uint256 maxPerVaultDay;
    }

    mapping(address => TokenPolicy) private _tokenPolicies;
    mapping(address => bool) public investorAllowed;
    mapping(address => mapping(address => bool)) public recipientAllowed;
    mapping(address => mapping(address => uint256)) private _balances;
    mapping(address => uint256) public totalLiability;

    uint256 public policyEpoch = 1;

    error InvalidInvestor();
    error InvalidRecipient();
    error InvalidToken();
    error InvalidAmount();
    error InvestorNotAllowed(address investor);
    error DepositsDisabled(address token);
    error UnexpectedTokenMovement();

    event Deposited(address indexed owner, address indexed token, uint256 amount);

    event InvestorAllowedChanged(address indexed investor, bool previousAllowed, bool allowed);

    event PolicyEpochAdvanced(uint256 previousEpoch, uint256 newEpoch);

    event RecipientAllowedChanged (
        address indexed owner,
        address indexed recipient,
        bool previousAllowed,
        bool allowed

    );

    event TokenPolicyChanged(
        address indexed token,
        TokenPolicy previousPolicy,
        TokenPolicy newPolicy
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

    function tokenPolicy(address token) external view returns (TokenPolicy memory) {
        return _tokenPolicies[token];
    }

    function setTokenPolicy(address token, TokenPolicy calldata policy)
        external
        onlyRole(POLICY_ROLE)
        {
            if (token == address(0)) revert InvalidToken();

            if ((policy.depositsEnabled || policy.withdrawalsEnabled) && token.code.length == 0) {
                revert InvalidToken();
            }

            TokenPolicy memory previousPolicy = _tokenPolicies[token];

            if (
                previousPolicy.depositsEnabled == policy.depositsEnabled 
                    && previousPolicy.withdrawalsEnabled == policy.withdrawalsEnabled
                    && previousPolicy.maxPerWithdrawal == policy.maxPerWithdrawal
                    && previousPolicy.maxPerOwnerDay == policy.maxPerOwnerDay
                    && previousPolicy.maxPerVaultDay == policy.maxPerVaultDay
            ) {
                return;
            }
            _tokenPolicies[token] = policy;

            uint256 previousEpoch = policyEpoch;
            policyEpoch = previousEpoch + 1;

            emit TokenPolicyChanged(token, previousPolicy, policy);
            emit PolicyEpochAdvanced(previousEpoch, policyEpoch);
            
        }
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();

        uint256 previousEpoch = policyEpoch;
        policyEpoch = previousEpoch + 1;

        emit PolicyEpochAdvanced(previousEpoch, policyEpoch);
    }    

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();

        uint256 previousEpoch = policyEpoch;
        policyEpoch = previousEpoch + 1;

        emit PolicyEpochAdvanced(previousEpoch, policyEpoch);
    }

    function balanceOf(address owner, address token) external view returns (uint256) {
        return _balances[owner][token];
    }

    function deposit(address token, uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (token == address(0) || token.code.length ==0) revert InvalidToken();

        address owner = _msgSender();

        if (!investorAllowed[owner]) revert InvestorNotAllowed(owner);
        if (!_tokenPolicies[token].depositsEnabled) revert DepositsDisabled(token);

        IERC20 asset = IERC20(token);

        uint256 ownerBefore = asset.balanceOf(owner);
        uint256 vaultBefore = asset.balanceOf(address(this));

        asset.safeTransferFrom(owner, address(this), amount);

        uint256 ownerAfter = asset.balanceOf(owner);
        uint256 vaultAfter = asset.balanceOf(address(this));

        if (
            ownerAfter > ownerBefore
                || ownerBefore - ownerAfter != amount
                || vaultAfter < vaultBefore 
                || vaultAfter - vaultBefore != amount

        ) {
            revert UnexpectedTokenMovement();
        }
        _balances[owner][token] += amount;
        totalLiability[token] += amount;

        emit Deposited(owner, token, amount);
    }

}
