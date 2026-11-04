pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {InstitutionalTokenCustodyVault} from "../src/InstitutionalTokenCustodyVault.sol";

contract InstitutionalTokenCustodyVaultTest is Test {
    bytes32 private constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    InstitutionalTokenCustodyVault private vault;
    address private admin;
    address private compliance;
    address private alice;

    function setUp() public {
        admin = makeAddr("admin");
        compliance = makeAddr("compliance");
        alice = makeAddr("alice");

        vault = new InstitutionalTokenCustodyVault(admin);

        vm.prank(admin);
        vault.grantRole(COMPLIANCE_ROLE, compliance);
    }

    function testComplianceRoleIdentifier() public view {
        assertEq(vault.COMPLIANCE_ROLE(), COMPLIANCE_ROLE);
    }

    function testComplianceCanApproveAndRevokeInvestor() public {
        assertFalse(vault.investorAllowed(alice));
        assertEq(vault.policyEpoch(), 1);

        vm.prank(compliance);
        vault.setInvestorAllowed(alice, true);

        assertTrue(vault.investorAllowed(alice));
        assertEq(vault.policyEpoch(), 2);

        vm.prank(compliance);
        vault.setInvestorAllowed(alice, false);

        assertFalse(vault.investorAllowed(alice));
        assertEq(vault.policyEpoch(), 3);
    }

    function testUnauthorizedCallerCannotChangeAllowlist() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, COMPLIANCE_ROLE)
        );

        vm.prank(alice);
        vault.setInvestorAllowed(alice, true);

        assertFalse(vault.investorAllowed(alice));
        assertEq(vault.policyEpoch(), 1);
    }

    function testRepeatedStatusDoesNotAdvanceEpoch() public {
        vm.startPrank(compliance);

        vault.setInvestorAllowed(alice, false);
        assertFalse(vault.investorAllowed(alice));
        assertEq(vault.policyEpoch(), 1);

        vault.setInvestorAllowed(alice, true);
        assertEq(vault.policyEpoch(), 2);

        vault.setInvestorAllowed(alice, true);
        assertTrue(vault.investorAllowed(alice));
        assertEq(vault.policyEpoch(), 2);

        vm.stopPrank();
    }

    function testZeroInvestorReverts() public {
        vm.expectRevert(InstitutionalTokenCustodyVault.InvalidInvestor.selector);

        vm.prank(compliance);
        vault.setInvestorAllowed(address(0), true);

        assertFalse(vault.investorAllowed(address(0)));
        assertEq(vault.policyEpoch(), 1);
    }
}
