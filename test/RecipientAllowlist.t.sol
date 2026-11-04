pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {InstitutionalTokenCustodyVault} from "../src/InstitutionalTokenCustodyVault.sol";

contract RecipientAllowlistTest is Test {
    bytes32 private constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    InstitutionalTokenCustodyVault private vault;
    address private admin;
    address private compliance;
    address private alice;
    address private bob;
    address private carol;

    event RecipientAllowedChanged(address indexed owner, address indexed recipient, bool previousAllowed, bool allowed);
    event PolicyEpochAdvanced(uint256 previousEpoch, uint256 newEpoch);

    function setUp() public {
        admin = makeAddr("admin");
        compliance = makeAddr("compliance");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        vault = new InstitutionalTokenCustodyVault(admin);

        vm.prank(admin);
        vault.grantRole(COMPLIANCE_ROLE, compliance);
    }

    function testComplianceCanApproveAndRevokeRecipient() public {
        assertFalse(vault.recipientAllowed(alice, bob));
        assertEq(vault.policyEpoch(), 1);

        vm.expectEmit(true, true, false, true, address(vault));
        emit RecipientAllowedChanged(alice, bob, false, true);
        vm.expectEmit(false, false, false, true, address(vault));
        emit PolicyEpochAdvanced(1, 2);
        vm.prank(compliance);
        vault.setRecipientAllowed(alice, bob, true);

        assertTrue(vault.recipientAllowed(alice, bob));
        assertEq(vault.policyEpoch(), 2);

        vm.expectEmit(true, true, false, true, address(vault));
        emit RecipientAllowedChanged(alice, bob, true, false);
        vm.expectEmit(false, false, false, true, address(vault));
        emit PolicyEpochAdvanced(2, 3);
        vm.prank(compliance);
        vault.setRecipientAllowed(alice, bob, false);

        assertFalse(vault.recipientAllowed(alice, bob));
        assertEq(vault.policyEpoch(), 3);
    }

    function testRecipientApprovalIsOwnerAndDirectionSpecific() public {
        vm.prank(compliance);
        vault.setRecipientAllowed(alice, bob, true);

        assertTrue(vault.recipientAllowed(alice, bob));
        assertFalse(vault.recipientAllowed(carol, bob));
        assertFalse(vault.recipientAllowed(bob, alice));
        assertFalse(vault.recipientAllowed(alice, carol));
        assertFalse(vault.recipientAllowed(alice, alice));

        vm.startPrank(compliance);
        vault.setRecipientAllowed(carol, bob, true);
        vault.setRecipientAllowed(alice, bob, false);
        vm.stopPrank();

        assertFalse(vault.recipientAllowed(alice, bob));
        assertTrue(vault.recipientAllowed(carol, bob));
        assertEq(vault.policyEpoch(), 4);
    }

    function testSelfRecipientRequiresExplicitApproval() public {
        vm.prank(compliance);
        vault.setInvestorAllowed(alice, true);

        assertTrue(vault.investorAllowed(alice));
        assertFalse(vault.recipientAllowed(alice, alice));

        vm.prank(compliance);
        vault.setRecipientAllowed(alice, alice, true);

        assertTrue(vault.recipientAllowed(alice, alice));
        assertEq(vault.policyEpoch(), 3);
    }

    function testRecipientConfigurationIsIndependentOfEligibility() public {
        assertFalse(vault.investorAllowed(alice));
        assertFalse(vault.investorAllowed(bob));

        vm.prank(compliance);
        vault.setRecipientAllowed(alice, bob, true);

        assertTrue(vault.recipientAllowed(alice, bob));
        assertFalse(vault.investorAllowed(alice));
        assertFalse(vault.investorAllowed(bob));
        assertEq(vault.policyEpoch(), 2);

        vm.startPrank(compliance);
        vault.setInvestorAllowed(alice, true);
        vault.setInvestorAllowed(bob, true);
        vault.setInvestorAllowed(bob, false);
        vm.stopPrank();

        assertTrue(vault.recipientAllowed(alice, bob));
        assertFalse(vault.investorAllowed(bob));
        assertEq(vault.policyEpoch(), 5);

        vm.prank(compliance);
        vault.setRecipientAllowed(alice, bob, false);

        assertFalse(vault.recipientAllowed(alice, bob));
        assertTrue(vault.investorAllowed(alice));
        assertFalse(vault.investorAllowed(bob));
        assertEq(vault.policyEpoch(), 6);
    }

    function testUnauthorizedCallerCannotConfigureRecipient() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, COMPLIANCE_ROLE)
        );
        vm.prank(alice);
        vault.setRecipientAllowed(alice, bob, true);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, COMPLIANCE_ROLE)
        );
        vm.prank(alice);
        vault.setRecipientAllowed(alice, bob, false);

        assertFalse(vault.recipientAllowed(alice, bob));
        assertEq(vault.policyEpoch(), 1);
    }

    function testAdminNeedsComplianceRoleToConfigureRecipient() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, COMPLIANCE_ROLE)
        );
        vm.prank(admin);
        vault.setRecipientAllowed(alice, bob, true);

        assertFalse(vault.recipientAllowed(alice, bob));
        assertEq(vault.policyEpoch(), 1);
    }

    function testRevokedComplianceCannotConfigureRecipient() public {
        vm.prank(compliance);
        vault.setRecipientAllowed(alice, bob, true);

        vm.prank(admin);
        vault.revokeRole(COMPLIANCE_ROLE, compliance);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, compliance, COMPLIANCE_ROLE
            )
        );
        vm.prank(compliance);
        vault.setRecipientAllowed(alice, bob, false);

        assertTrue(vault.recipientAllowed(alice, bob));
        assertEq(vault.policyEpoch(), 2);
    }

    function testZeroOwnerRejected() public {
        vm.expectRevert(InstitutionalTokenCustodyVault.InvalidInvestor.selector);
        vm.prank(compliance);
        vault.setRecipientAllowed(address(0), bob, true);

        vm.expectRevert(InstitutionalTokenCustodyVault.InvalidInvestor.selector);
        vm.prank(compliance);
        vault.setRecipientAllowed(address(0), bob, false);

        assertFalse(vault.recipientAllowed(address(0), bob));
        assertEq(vault.policyEpoch(), 1);
    }

    function testZeroRecipientRejected() public {
        vm.expectRevert(InstitutionalTokenCustodyVault.InvalidRecipient.selector);
        vm.prank(compliance);
        vault.setRecipientAllowed(alice, address(0), true);

        vm.expectRevert(InstitutionalTokenCustodyVault.InvalidRecipient.selector);
        vm.prank(compliance);
        vault.setRecipientAllowed(alice, address(0), false);

        assertFalse(vault.recipientAllowed(alice, address(0)));
        assertEq(vault.policyEpoch(), 1);
    }

    function testVaultRecipientRejected() public {
        vm.expectRevert(InstitutionalTokenCustodyVault.InvalidRecipient.selector);
        vm.prank(compliance);
        vault.setRecipientAllowed(alice, address(vault), true);

        vm.expectRevert(InstitutionalTokenCustodyVault.InvalidRecipient.selector);
        vm.prank(compliance);
        vault.setRecipientAllowed(alice, address(vault), false);

        assertFalse(vault.recipientAllowed(alice, address(vault)));
        assertEq(vault.policyEpoch(), 1);
    }

    function testRepeatedDeniedRecipientDoesNotChangeStateOrEmitEvents() public {
        vm.recordLogs();
        vm.prank(compliance);
        vault.setRecipientAllowed(alice, bob, false);

        assertEq(vm.getRecordedLogs().length, 0);
        assertFalse(vault.recipientAllowed(alice, bob));
        assertEq(vault.policyEpoch(), 1);
    }

    function testRepeatedApprovedRecipientDoesNotChangeStateOrEmitEvents() public {
        vm.prank(compliance);
        vault.setRecipientAllowed(alice, bob, true);

        vm.recordLogs();
        vm.prank(compliance);
        vault.setRecipientAllowed(alice, bob, true);

        assertEq(vm.getRecordedLogs().length, 0);
        assertTrue(vault.recipientAllowed(alice, bob));
        assertEq(vault.policyEpoch(), 2);
    }
}
