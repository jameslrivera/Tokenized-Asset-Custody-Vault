pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {InstitutionalTokenCustodyVault} from "../src/InstitutionalTokenCustodyVault.sol";
import {SecurityToken} from "../src/SecurityToken.sol";

contract VaultDepositTest is Test {
    bytes32 private constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    bytes32 private constant POLICY_ROLE = keccak256("POLICY_ROLE");
    bytes32 private constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    uint256 private constant INITIAL_BALANCE = 150_000_000;
    uint256 private constant DEPOSIT_AMOUNT = 100_000_000;
    uint256 private constant SMALL_DEPOSIT = 25_000_000;

    InstitutionalTokenCustodyVault private vault;
    SecurityToken private token;
    address private admin;
    address private compliance;
    address private policyManager;
    address private pauser;
    address private minter;
    address private alice;
    address private bob;
    address private outsider;

    event Deposited(address indexed owner, address indexed token, uint256 amount);

    function setUp() public {
        admin = makeAddr("admin");
        compliance = makeAddr("compliance");
        policyManager = makeAddr("policyManager");
        pauser = makeAddr("pauser");
        minter = makeAddr("minter");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        outsider = makeAddr("outsider");
        vault = new InstitutionalTokenCustodyVault(admin);
        token = new SecurityToken(admin, minter);

        vm.startPrank(admin);
        vault.grantRole(COMPLIANCE_ROLE, compliance);
        vault.grantRole(POLICY_ROLE, policyManager);
        vault.grantRole(PAUSER_ROLE, pauser);
        vm.stopPrank();

        vm.startPrank(compliance);
        vault.setInvestorAllowed(alice, true);
        vault.setInvestorAllowed(bob, true);
        vm.stopPrank();

        vm.prank(policyManager);
        vault.setTokenPolicy(address(token), _enabledPolicy());

        vm.startPrank(minter);
        token.mint(alice, INITIAL_BALANCE);
        token.mint(bob, INITIAL_BALANCE);
        vm.stopPrank();
    }

    function testApprovalDoesNotMoveTokensOrCreditVault() public {
        _approve(alice, DEPOSIT_AMOUNT);

        assertEq(token.allowance(alice, address(vault)), DEPOSIT_AMOUNT);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        _assertAccounting(0, 0, 0);
    }

    function testEligibleInvestorCanDepositExactAmount() public {
        uint256 epochBefore = vault.policyEpoch();
        assertFalse(vault.recipientAllowed(alice, alice));
        _approve(alice, DEPOSIT_AMOUNT);

        vm.expectEmit(true, true, false, true, address(vault));
        emit Deposited(alice, address(token), DEPOSIT_AMOUNT);
        _deposit(alice, DEPOSIT_AMOUNT);

        assertEq(token.balanceOf(alice), INITIAL_BALANCE - DEPOSIT_AMOUNT);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE);
        assertEq(token.allowance(alice, address(vault)), 0);
        assertEq(token.totalSupply(), INITIAL_BALANCE * 2);
        assertEq(vault.policyEpoch(), epochBefore);
        _assertAccounting(DEPOSIT_AMOUNT, 0, 0);
    }

    function testRepeatedDepositsAccumulate() public {
        _approve(alice, SMALL_DEPOSIT * 2);
        _deposit(alice, SMALL_DEPOSIT);
        _deposit(alice, SMALL_DEPOSIT);

        assertEq(token.balanceOf(alice), INITIAL_BALANCE - SMALL_DEPOSIT * 2);
        assertEq(token.allowance(alice, address(vault)), 0);
        _assertAccounting(SMALL_DEPOSIT * 2, 0, 0);
    }

    function testDifferentOwnersHaveSeparateBalancesAndSharedLiability() public {
        _approve(alice, DEPOSIT_AMOUNT);
        _approve(bob, SMALL_DEPOSIT);
        _deposit(alice, DEPOSIT_AMOUNT);
        _deposit(bob, SMALL_DEPOSIT);

        assertEq(token.balanceOf(alice), INITIAL_BALANCE - DEPOSIT_AMOUNT);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE - SMALL_DEPOSIT);
        assertEq(vault.balanceOf(outsider, address(token)), 0);
        _assertAccounting(DEPOSIT_AMOUNT, SMALL_DEPOSIT, 0);
    }

    function testDepositCreditsOnlyCallerEvenWithAnotherOwnersApproval() public {
        _approve(alice, DEPOSIT_AMOUNT);
        _approve(bob, DEPOSIT_AMOUNT);
        _deposit(bob, SMALL_DEPOSIT);

        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token.allowance(alice, address(vault)), DEPOSIT_AMOUNT);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE - SMALL_DEPOSIT);
        assertEq(token.allowance(bob, address(vault)), DEPOSIT_AMOUNT - SMALL_DEPOSIT);
        _assertAccounting(0, SMALL_DEPOSIT, 0);
    }

    function testDifferentDecimalsAndTokensKeepSeparateAccounting() public {
        DepositEighteenDecimalToken otherToken = new DepositEighteenDecimalToken();
        otherToken.mint(alice, 3e18);

        vm.prank(policyManager);
        vault.setTokenPolicy(address(otherToken), _enabledPolicy());

        _approve(alice, DEPOSIT_AMOUNT);
        _deposit(alice, DEPOSIT_AMOUNT);

        vm.prank(alice);
        assertTrue(otherToken.approve(address(vault), 2e18));
        vm.prank(alice);
        vault.deposit(address(otherToken), 2e18);

        assertEq(token.decimals(), 6);
        assertEq(otherToken.decimals(), 18);
        assertEq(otherToken.balanceOf(alice), 1e18);
        assertEq(otherToken.balanceOf(address(vault)), 2e18);
        assertEq(vault.balanceOf(alice, address(otherToken)), 2e18);
        assertEq(vault.balanceOf(bob, address(otherToken)), 0);
        assertEq(vault.totalLiability(address(otherToken)), 2e18);
        _assertAccounting(DEPOSIT_AMOUNT, 0, 0);
    }

    function testDepositRejectsZeroAmount() public {
        _approve(alice, DEPOSIT_AMOUNT);

        vm.expectRevert(InstitutionalTokenCustodyVault.InvalidAmount.selector);
        _deposit(alice, 0);

        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token.allowance(alice, address(vault)), DEPOSIT_AMOUNT);
        _assertAccounting(0, 0, 0);
    }

    function testDepositRejectsZeroAndNonContractTokens() public {
        vm.expectRevert(InstitutionalTokenCustodyVault.InvalidToken.selector);
        vm.prank(alice);
        vault.deposit(address(0), DEPOSIT_AMOUNT);

        vm.expectRevert(InstitutionalTokenCustodyVault.InvalidToken.selector);
        vm.prank(alice);
        vault.deposit(outsider, DEPOSIT_AMOUNT);

        assertEq(vault.balanceOf(alice, address(0)), 0);
        assertEq(vault.totalLiability(address(0)), 0);
        assertEq(vault.balanceOf(alice, outsider), 0);
        assertEq(vault.totalLiability(outsider), 0);
        _assertAccounting(0, 0, 0);
    }

    function testUnknownTokenCannotBeDeposited() public {
        SecurityToken unknownToken = new SecurityToken(admin, minter);
        vm.prank(minter);
        unknownToken.mint(alice, INITIAL_BALANCE);
        vm.prank(alice);
        assertTrue(unknownToken.approve(address(vault), DEPOSIT_AMOUNT));

        vm.expectRevert(
            abi.encodeWithSelector(InstitutionalTokenCustodyVault.DepositsDisabled.selector, address(unknownToken))
        );
        vm.prank(alice);
        vault.deposit(address(unknownToken), DEPOSIT_AMOUNT);

        assertEq(unknownToken.balanceOf(alice), INITIAL_BALANCE);
        assertEq(unknownToken.balanceOf(address(vault)), 0);
        assertEq(unknownToken.allowance(alice, address(vault)), DEPOSIT_AMOUNT);
        assertEq(vault.balanceOf(alice, address(unknownToken)), 0);
        assertEq(vault.totalLiability(address(unknownToken)), 0);
        _assertAccounting(0, 0, 0);
    }

    function testDisablingDepositsPreservesExistingAccounting() public {
        _approve(alice, SMALL_DEPOSIT * 2);
        _deposit(alice, SMALL_DEPOSIT);
        InstitutionalTokenCustodyVault.TokenPolicy memory policy = _enabledPolicy();
        policy.depositsEnabled = false;
        vm.prank(policyManager);
        vault.setTokenPolicy(address(token), policy);
        uint256 epochBefore = vault.policyEpoch();

        vm.expectRevert(
            abi.encodeWithSelector(InstitutionalTokenCustodyVault.DepositsDisabled.selector, address(token))
        );
        _deposit(alice, SMALL_DEPOSIT);

        assertEq(token.balanceOf(alice), INITIAL_BALANCE - SMALL_DEPOSIT);
        assertEq(token.allowance(alice, address(vault)), SMALL_DEPOSIT);
        assertEq(vault.policyEpoch(), epochBefore);
        _assertAccounting(SMALL_DEPOSIT, 0, 0);
    }

    function testIneligibleInvestorCannotDeposit() public {
        vm.prank(minter);
        token.mint(outsider, INITIAL_BALANCE);
        _approve(outsider, DEPOSIT_AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(InstitutionalTokenCustodyVault.InvestorNotAllowed.selector, outsider));
        _deposit(outsider, DEPOSIT_AMOUNT);

        assertEq(token.balanceOf(outsider), INITIAL_BALANCE);
        assertEq(token.allowance(outsider, address(vault)), DEPOSIT_AMOUNT);
        assertEq(vault.balanceOf(outsider, address(token)), 0);
        _assertAccounting(0, 0, 0);
    }

    function testDelistingInvestorPreservesExistingAccounting() public {
        _approve(alice, SMALL_DEPOSIT * 2);
        _deposit(alice, SMALL_DEPOSIT);
        vm.prank(compliance);
        vault.setInvestorAllowed(alice, false);
        uint256 epochBefore = vault.policyEpoch();

        vm.expectRevert(abi.encodeWithSelector(InstitutionalTokenCustodyVault.InvestorNotAllowed.selector, alice));
        _deposit(alice, SMALL_DEPOSIT);

        assertEq(token.balanceOf(alice), INITIAL_BALANCE - SMALL_DEPOSIT);
        assertEq(token.allowance(alice, address(vault)), SMALL_DEPOSIT);
        assertEq(vault.policyEpoch(), epochBefore);
        _assertAccounting(SMALL_DEPOSIT, 0, 0);
    }

    function testDepositRequiresSufficientAllowance() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 0, DEPOSIT_AMOUNT)
        );
        _deposit(alice, DEPOSIT_AMOUNT);
        assertEq(token.allowance(alice, address(vault)), 0);

        _approve(alice, DEPOSIT_AMOUNT - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), DEPOSIT_AMOUNT - 1, DEPOSIT_AMOUNT
            )
        );
        _deposit(alice, DEPOSIT_AMOUNT);

        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token.allowance(alice, address(vault)), DEPOSIT_AMOUNT - 1);
        _assertAccounting(0, 0, 0);
    }

    function testDepositRequiresSufficientTokenBalance() public {
        uint256 amount = INITIAL_BALANCE + 1;
        _approve(alice, amount);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, INITIAL_BALANCE, amount)
        );
        _deposit(alice, amount);

        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token.allowance(alice, address(vault)), amount);
        assertEq(token.totalSupply(), INITIAL_BALANCE * 2);
        _assertAccounting(0, 0, 0);
    }

    function testPauseBlocksDepositAndUnpauseRestoresIt() public {
        _approve(alice, SMALL_DEPOSIT * 2);
        _deposit(alice, SMALL_DEPOSIT);
        vm.prank(pauser);
        vault.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        _deposit(alice, SMALL_DEPOSIT);

        assertEq(token.balanceOf(alice), INITIAL_BALANCE - SMALL_DEPOSIT);
        assertEq(token.allowance(alice, address(vault)), SMALL_DEPOSIT);
        _assertAccounting(SMALL_DEPOSIT, 0, 0);

        vm.prank(admin);
        vault.unpause();
        _deposit(alice, SMALL_DEPOSIT);

        assertEq(token.balanceOf(alice), INITIAL_BALANCE - SMALL_DEPOSIT * 2);
        assertEq(token.allowance(alice, address(vault)), 0);
        _assertAccounting(SMALL_DEPOSIT * 2, 0, 0);
    }

    function testDepositsDoNotRequireWithdrawalPermissionOrCapacity() public {
        InstitutionalTokenCustodyVault.TokenPolicy memory policy;
        policy.depositsEnabled = true;
        vm.prank(policyManager);
        vault.setTokenPolicy(address(token), policy);
        _approve(alice, DEPOSIT_AMOUNT);

        _deposit(alice, DEPOSIT_AMOUNT);

        assertEq(token.balanceOf(alice), INITIAL_BALANCE - DEPOSIT_AMOUNT);
        _assertAccounting(DEPOSIT_AMOUNT, 0, 0);
    }

    function testDirectTransfersRemainUncreditedSurplus() public {
        vm.prank(bob);
        assertTrue(token.transfer(address(vault), SMALL_DEPOSIT));
        _assertAccounting(0, 0, SMALL_DEPOSIT);

        _approve(alice, DEPOSIT_AMOUNT);
        _deposit(alice, DEPOSIT_AMOUNT);
        _assertAccounting(DEPOSIT_AMOUNT, 0, SMALL_DEPOSIT);

        vm.prank(bob);
        assertTrue(token.transfer(address(vault), SMALL_DEPOSIT));

        assertEq(token.balanceOf(alice), INITIAL_BALANCE - DEPOSIT_AMOUNT);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE - SMALL_DEPOSIT * 2);
        _assertAccounting(DEPOSIT_AMOUNT, 0, SMALL_DEPOSIT * 2);
    }

    function testDepositAcceptsSingleRawUnit() public {
        _approve(alice, 1);
        _deposit(alice, 1);

        assertEq(token.balanceOf(alice), INITIAL_BALANCE - 1);
        _assertAccounting(1, 0, 0);
    }

    function testFuzzDepositsPreserveAccounting(uint96 aliceAmount, uint96 bobAmount, uint96 surplusAmount) public {
        uint256 aliceDeposit = uint256(aliceAmount) + 1;
        uint256 bobDeposit = uint256(bobAmount) + 1;
        uint256 surplus = uint256(surplusAmount);
        uint256 epochBefore = vault.policyEpoch();

        vm.startPrank(minter);
        token.mint(alice, aliceDeposit);
        token.mint(bob, bobDeposit + surplus);
        vm.stopPrank();

        _approve(alice, aliceDeposit);
        _approve(bob, bobDeposit);
        _deposit(alice, aliceDeposit);
        vm.prank(bob);
        assertTrue(token.transfer(address(vault), surplus));
        _deposit(bob, bobDeposit);

        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE);
        assertEq(token.allowance(alice, address(vault)), 0);
        assertEq(token.allowance(bob, address(vault)), 0);
        assertEq(token.totalSupply(), INITIAL_BALANCE * 2 + aliceDeposit + bobDeposit + surplus);
        assertEq(vault.policyEpoch(), epochBefore);
        _assertAccounting(aliceDeposit, bobDeposit, surplus);
    }

    function _enabledPolicy() private pure returns (InstitutionalTokenCustodyVault.TokenPolicy memory) {
        return InstitutionalTokenCustodyVault.TokenPolicy({
            depositsEnabled: true,
            withdrawalsEnabled: true,
            maxPerWithdrawal: DEPOSIT_AMOUNT,
            maxPerOwnerDay: 250_000_000,
            maxPerVaultDay: 500_000_000
        });
    }

    function _approve(address owner, uint256 amount) private {
        vm.prank(owner);
        assertTrue(token.approve(address(vault), amount));
    }

    function _deposit(address owner, uint256 amount) private {
        vm.prank(owner);
        vault.deposit(address(token), amount);
    }

    function _assertAccounting(uint256 aliceCredit, uint256 bobCredit, uint256 surplus) private view {
        assertEq(vault.balanceOf(alice, address(token)), aliceCredit);
        assertEq(vault.balanceOf(bob, address(token)), bobCredit);
        assertEq(vault.totalLiability(address(token)), aliceCredit + bobCredit);
        assertEq(token.balanceOf(address(vault)), aliceCredit + bobCredit + surplus);
    }
}

contract DepositEighteenDecimalToken is ERC20 {
    constructor() ERC20("Eighteen Decimal Test Token", "T18") {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }
}
