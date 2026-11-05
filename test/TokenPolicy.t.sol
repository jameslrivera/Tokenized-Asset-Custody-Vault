pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {InstitutionalTokenCustodyVault} from "../src/InstitutionalTokenCustodyVault.sol";
import {SecurityToken} from "../src/SecurityToken.sol";

contract TokenPolicyTest is Test {
    bytes32 private constant POLICY_ROLE = keccak256("POLICY_ROLE");
    bytes32 private constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    InstitutionalTokenCustodyVault private vault;
    SecurityToken private token;
    address private admin;
    address private policyManager;
    address private alice;
    address private bob;

    event TokenPolicyChanged(
        address indexed token,
        InstitutionalTokenCustodyVault.TokenPolicy previousPolicy,
        InstitutionalTokenCustodyVault.TokenPolicy newPolicy
    );
    event PolicyEpochAdvanced(uint256 previousEpoch, uint256 newEpoch);

    function setUp() public {
        admin = makeAddr("admin");
        policyManager = makeAddr("policyManager");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        vault = new InstitutionalTokenCustodyVault(admin);
        token = new SecurityToken(admin, admin);

        vm.prank(admin);
        vault.grantRole(POLICY_ROLE, policyManager);
    }

    function testUnconfiguredTokenIsDisabled() public view {
        InstitutionalTokenCustodyVault.TokenPolicy memory emptyPolicy;

        _assertPolicy(address(token), emptyPolicy);
        assertEq(vault.POLICY_ROLE(), POLICY_ROLE);
        assertEq(vault.policyEpoch(), 1);
    }

    function testPolicyManagerCanConfigureAndReplacePolicy() public {
        InstitutionalTokenCustodyVault.TokenPolicy memory emptyPolicy;
        InstitutionalTokenCustodyVault.TokenPolicy memory initialPolicy = _enabledPolicy();

        vm.expectEmit(true, false, false, true, address(vault));
        emit TokenPolicyChanged(address(token), emptyPolicy, initialPolicy);
        vm.expectEmit(false, false, false, true, address(vault));
        emit PolicyEpochAdvanced(1, 2);
        _setPolicy(address(token), initialPolicy);

        _assertPolicy(address(token), initialPolicy);
        assertEq(vault.policyEpoch(), 2);

        InstitutionalTokenCustodyVault.TokenPolicy memory replacement = _enabledPolicy();
        replacement.depositsEnabled = false;
        replacement.maxPerWithdrawal = 50_000_000;
        replacement.maxPerOwnerDay = 125_000_000;
        replacement.maxPerVaultDay = 300_000_000;

        vm.expectEmit(true, false, false, true, address(vault));
        emit TokenPolicyChanged(address(token), initialPolicy, replacement);
        vm.expectEmit(false, false, false, true, address(vault));
        emit PolicyEpochAdvanced(2, 3);
        _setPolicy(address(token), replacement);

        _assertPolicy(address(token), replacement);
        assertEq(vault.policyEpoch(), 3);
    }

    function testDepositAndWithdrawalFlagsAreIndependent() public {
        InstitutionalTokenCustodyVault.TokenPolicy memory policy = _enabledPolicy();
        _setPolicy(address(token), policy);

        policy.depositsEnabled = false;
        _setPolicy(address(token), policy);
        _assertPolicy(address(token), policy);
        assertEq(vault.policyEpoch(), 3);

        policy.withdrawalsEnabled = false;
        _setPolicy(address(token), policy);
        _assertPolicy(address(token), policy);
        assertEq(vault.policyEpoch(), 4);

        policy.depositsEnabled = true;
        _setPolicy(address(token), policy);
        _assertPolicy(address(token), policy);
        assertEq(vault.policyEpoch(), 5);

        policy.withdrawalsEnabled = true;
        _setPolicy(address(token), policy);
        _assertPolicy(address(token), policy);
        assertEq(vault.policyEpoch(), 6);
    }

    function testEachLimitCanChangeWithoutChangingPermissions() public {
        InstitutionalTokenCustodyVault.TokenPolicy memory policy = _enabledPolicy();
        _setPolicy(address(token), policy);

        policy.maxPerWithdrawal -= 1;
        _setPolicy(address(token), policy);
        _assertPolicy(address(token), policy);
        assertEq(vault.policyEpoch(), 3);

        policy.maxPerOwnerDay -= 1;
        _setPolicy(address(token), policy);
        _assertPolicy(address(token), policy);
        assertEq(vault.policyEpoch(), 4);

        policy.maxPerVaultDay -= 1;
        _setPolicy(address(token), policy);
        _assertPolicy(address(token), policy);
        assertEq(vault.policyEpoch(), 5);
    }

    function testFuzzPolicyPreservesExactCaps(uint256 perWithdrawal, uint256 perOwner, uint256 perVault) public {
        InstitutionalTokenCustodyVault.TokenPolicy memory policy = InstitutionalTokenCustodyVault.TokenPolicy({
            depositsEnabled: true,
            withdrawalsEnabled: true,
            maxPerWithdrawal: perWithdrawal,
            maxPerOwnerDay: perOwner,
            maxPerVaultDay: perVault
        });

        _setPolicy(address(token), policy);

        _assertPolicy(address(token), policy);
        assertEq(vault.policyEpoch(), 2);
    }

    function testZeroCapsAreValidConfiguration() public {
        InstitutionalTokenCustodyVault.TokenPolicy memory policy;
        policy.depositsEnabled = true;
        policy.withdrawalsEnabled = true;

        _setPolicy(address(token), policy);

        _assertPolicy(address(token), policy);
        assertEq(vault.policyEpoch(), 2);
    }

    function testCapsDoNotRequireAnOrderingOrUpperBound() public {
        InstitutionalTokenCustodyVault.TokenPolicy memory policy = _enabledPolicy();
        policy.maxPerWithdrawal = type(uint256).max;
        policy.maxPerOwnerDay = 1;
        policy.maxPerVaultDay = 0;

        _setPolicy(address(token), policy);

        _assertPolicy(address(token), policy);
        assertEq(vault.policyEpoch(), 2);
    }

    function testPoliciesAreIsolatedByToken() public {
        SecurityToken otherToken = new SecurityToken(admin, admin);
        InstitutionalTokenCustodyVault.TokenPolicy memory emptyPolicy;
        InstitutionalTokenCustodyVault.TokenPolicy memory firstPolicy = _enabledPolicy();
        InstitutionalTokenCustodyVault.TokenPolicy memory secondPolicy = _enabledPolicy();
        secondPolicy.withdrawalsEnabled = false;
        secondPolicy.maxPerWithdrawal = 2_000_000;

        _setPolicy(address(token), firstPolicy);
        _assertPolicy(address(otherToken), emptyPolicy);

        _setPolicy(address(otherToken), secondPolicy);

        _assertPolicy(address(token), firstPolicy);
        _assertPolicy(address(otherToken), secondPolicy);
        assertEq(vault.policyEpoch(), 3);
    }

    function testTokenPolicyAndAllowlistsShareEpoch() public {
        vm.prank(admin);
        vault.grantRole(COMPLIANCE_ROLE, alice);

        vm.prank(alice);
        vault.setInvestorAllowed(alice, true);
        assertEq(vault.policyEpoch(), 2);

        InstitutionalTokenCustodyVault.TokenPolicy memory policy = _enabledPolicy();
        _setPolicy(address(token), policy);
        assertEq(vault.policyEpoch(), 3);

        vm.prank(alice);
        vault.setRecipientAllowed(alice, bob, true);

        _assertPolicy(address(token), policy);
        assertTrue(vault.investorAllowed(alice));
        assertTrue(vault.recipientAllowed(alice, bob));
        assertEq(vault.policyEpoch(), 4);
    }

    function testRepeatedDefaultPolicyDoesNotChangeStateOrEmitEvents() public {
        InstitutionalTokenCustodyVault.TokenPolicy memory policy;

        vm.recordLogs();
        _setPolicy(address(token), policy);

        assertEq(vm.getRecordedLogs().length, 0);
        _assertPolicy(address(token), policy);
        assertEq(vault.policyEpoch(), 1);
    }

    function testRepeatedConfiguredPolicyDoesNotChangeStateOrEmitEvents() public {
        InstitutionalTokenCustodyVault.TokenPolicy memory policy = _enabledPolicy();
        _setPolicy(address(token), policy);

        vm.recordLogs();
        _setPolicy(address(token), policy);

        assertEq(vm.getRecordedLogs().length, 0);
        _assertPolicy(address(token), policy);
        assertEq(vault.policyEpoch(), 2);
    }

    function testUnauthorizedCallerCannotChangeOrRepeatPolicy() public {
        InstitutionalTokenCustodyVault.TokenPolicy memory previousPolicy = _enabledPolicy();
        InstitutionalTokenCustodyVault.TokenPolicy memory replacement = _enabledPolicy();
        replacement.withdrawalsEnabled = false;
        _setPolicy(address(token), previousPolicy);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, POLICY_ROLE)
        );
        vm.prank(alice);
        vault.setTokenPolicy(address(token), previousPolicy);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, POLICY_ROLE)
        );
        vm.prank(alice);
        vault.setTokenPolicy(address(token), replacement);

        _assertPolicy(address(token), previousPolicy);
        assertEq(vault.policyEpoch(), 2);
    }

    function testAdminNeedsPolicyRoleToConfigureToken() public {
        InstitutionalTokenCustodyVault.TokenPolicy memory policy = _enabledPolicy();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, POLICY_ROLE)
        );
        vm.prank(admin);
        vault.setTokenPolicy(address(token), policy);

        InstitutionalTokenCustodyVault.TokenPolicy memory emptyPolicy;
        _assertPolicy(address(token), emptyPolicy);
        assertEq(vault.policyEpoch(), 1);
    }

    function testComplianceRoleCannotConfigureToken() public {
        vm.prank(admin);
        vault.grantRole(COMPLIANCE_ROLE, alice);
        InstitutionalTokenCustodyVault.TokenPolicy memory policy = _enabledPolicy();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, POLICY_ROLE)
        );
        vm.prank(alice);
        vault.setTokenPolicy(address(token), policy);

        InstitutionalTokenCustodyVault.TokenPolicy memory emptyPolicy;
        _assertPolicy(address(token), emptyPolicy);
        assertEq(vault.policyEpoch(), 1);
    }

    function testRevokedPolicyManagerCannotChangePolicy() public {
        InstitutionalTokenCustodyVault.TokenPolicy memory previousPolicy = _enabledPolicy();
        InstitutionalTokenCustodyVault.TokenPolicy memory replacement = _enabledPolicy();
        replacement.maxPerVaultDay = 1;
        _setPolicy(address(token), previousPolicy);

        vm.prank(admin);
        vault.revokeRole(POLICY_ROLE, policyManager);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, policyManager, POLICY_ROLE)
        );
        vm.prank(policyManager);
        vault.setTokenPolicy(address(token), replacement);

        _assertPolicy(address(token), previousPolicy);
        assertEq(vault.policyEpoch(), 2);
    }

    function testZeroTokenRejectedEvenForDisabledNoOp() public {
        InstitutionalTokenCustodyVault.TokenPolicy memory emptyPolicy;
        InstitutionalTokenCustodyVault.TokenPolicy memory enabledPolicy = _enabledPolicy();

        vm.expectRevert(InstitutionalTokenCustodyVault.InvalidToken.selector);
        _setPolicy(address(0), emptyPolicy);

        vm.expectRevert(InstitutionalTokenCustodyVault.InvalidToken.selector);
        _setPolicy(address(0), enabledPolicy);

        _assertPolicy(address(0), emptyPolicy);
        assertEq(vault.policyEpoch(), 1);
    }

    function testCannotEnableEitherPathForAddressWithoutCode() public {
        InstitutionalTokenCustodyVault.TokenPolicy memory policy = _enabledPolicy();
        policy.withdrawalsEnabled = false;

        vm.expectRevert(InstitutionalTokenCustodyVault.InvalidToken.selector);
        _setPolicy(alice, policy);

        policy.depositsEnabled = false;
        policy.withdrawalsEnabled = true;

        vm.expectRevert(InstitutionalTokenCustodyVault.InvalidToken.selector);
        _setPolicy(alice, policy);

        policy.depositsEnabled = true;

        vm.expectRevert(InstitutionalTokenCustodyVault.InvalidToken.selector);
        _setPolicy(alice, policy);

        InstitutionalTokenCustodyVault.TokenPolicy memory emptyPolicy;
        _assertPolicy(alice, emptyPolicy);
        assertEq(vault.policyEpoch(), 1);
    }

    function testDisabledPolicyCanBeStoredForAddressWithoutCode() public {
        InstitutionalTokenCustodyVault.TokenPolicy memory policy = _enabledPolicy();
        policy.depositsEnabled = false;
        policy.withdrawalsEnabled = false;

        _setPolicy(alice, policy);

        _assertPolicy(alice, policy);
        assertEq(vault.policyEpoch(), 2);
    }

    function testPolicyManagerCanDisableTokenAfterCodeIsRemoved() public {
        InstitutionalTokenCustodyVault.TokenPolicy memory policy = _enabledPolicy();
        _setPolicy(address(token), policy);
        vm.etch(address(token), hex"");

        vm.expectRevert(InstitutionalTokenCustodyVault.InvalidToken.selector);
        _setPolicy(address(token), policy);

        _assertPolicy(address(token), policy);
        assertEq(vault.policyEpoch(), 2);

        policy.depositsEnabled = false;
        policy.withdrawalsEnabled = false;
        _setPolicy(address(token), policy);

        _assertPolicy(address(token), policy);
        assertEq(vault.policyEpoch(), 3);
    }

    function _enabledPolicy() private pure returns (InstitutionalTokenCustodyVault.TokenPolicy memory) {
        return InstitutionalTokenCustodyVault.TokenPolicy({
            depositsEnabled: true,
            withdrawalsEnabled: true,
            maxPerWithdrawal: 100_000_000,
            maxPerOwnerDay: 250_000_000,
            maxPerVaultDay: 500_000_000
        });
    }

    function _setPolicy(address asset, InstitutionalTokenCustodyVault.TokenPolicy memory policy) private {
        vm.prank(policyManager);
        vault.setTokenPolicy(asset, policy);
    }

    function _assertPolicy(address asset, InstitutionalTokenCustodyVault.TokenPolicy memory expected) private view {
        InstitutionalTokenCustodyVault.TokenPolicy memory actual = vault.tokenPolicy(asset);
        assertEq(actual.depositsEnabled, expected.depositsEnabled);
        assertEq(actual.withdrawalsEnabled, expected.withdrawalsEnabled);
        assertEq(actual.maxPerWithdrawal, expected.maxPerWithdrawal);
        assertEq(actual.maxPerOwnerDay, expected.maxPerOwnerDay);
        assertEq(actual.maxPerVaultDay, expected.maxPerVaultDay);
    }
}
