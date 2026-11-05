pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {InstitutionalTokenCustodyVault} from "../src/InstitutionalTokenCustodyVault.sol";

contract AdversarialDepositToken is ERC20 {
    enum TransferMode {
        Normal,
        ReturnFalse,
        RevertAfterTransfer,
        ReceiverFee,
        SenderFee,
        NoMovement,
        OwnerIncrease,
        VaultDecrease,
        ReceiverBonus,
        NoReturn
    }

    TransferMode public mode;

    error TransferRejected();

    constructor() ERC20("Adversarial Deposit Token", "ADT") {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }

    function setMode(TransferMode nextMode) external {
        mode = nextMode;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (mode == TransferMode.NoMovement) {
            _spendAllowance(from, _msgSender(), amount);
            return true;
        }

        super.transferFrom(from, to, amount);

        if (mode == TransferMode.ReturnFalse) return false;
        if (mode == TransferMode.RevertAfterTransfer) revert TransferRejected();
        if (mode == TransferMode.ReceiverFee) _burn(to, 1);
        if (mode == TransferMode.SenderFee) _burn(from, 1);
        if (mode == TransferMode.OwnerIncrease) _mint(from, amount + 1);
        if (mode == TransferMode.VaultDecrease) _burn(to, amount + 1);
        if (mode == TransferMode.ReceiverBonus) _mint(to, 1);

        if (mode == TransferMode.NoReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }

        return true;
    }
}

contract CallbackDepositToken is ERC20 {
    InstitutionalTokenCustodyVault private immutable vault;

    uint256 public constant OWN_FUNDS = 500;
    uint256 public constant CALLBACK_AMOUNT = 10;
    bool public callbackEnabled;
    bool public bubbleFailure;
    bool public callbackSucceeded;
    uint256 public callbackAttempts;
    bytes public callbackError;

    constructor(InstitutionalTokenCustodyVault target) ERC20("Callback Deposit Token", "CDT") {
        vault = target;
        _mint(address(this), OWN_FUNDS);
        _approve(address(this), address(target), OWN_FUNDS);
    }

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }

    function configureCallback(bool enabled, bool shouldBubble) external {
        callbackEnabled = enabled;
        bubbleFailure = shouldBubble;
    }

    function depositOwnTokens() external {
        vault.deposit(address(this), CALLBACK_AMOUNT);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);

        if (callbackEnabled && _msgSender() == address(vault)) {
            callbackEnabled = false;
            callbackAttempts += 1;

            (bool succeeded, bytes memory result) = address(vault)
                .call(abi.encodeCall(InstitutionalTokenCustodyVault.deposit, (address(this), CALLBACK_AMOUNT)));
            callbackSucceeded = succeeded;
            callbackError = result;

            if (!succeeded && bubbleFailure) {
                assembly ("memory-safe") {
                    revert(add(result, 32), mload(result))
                }
            }
        }

        return true;
    }
}

contract VaultDepositAdversarialTest is Test {
    uint256 private constant INITIAL_FUNDS = 1000;
    uint256 private constant INITIAL_ALLOWANCE = 300;
    uint256 private constant PREVIOUS_DEPOSIT = 100;
    uint256 private constant ATTEMPT = 50;
    bytes32 private constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    bytes32 private constant POLICY_ROLE = keccak256("POLICY_ROLE");

    InstitutionalTokenCustodyVault private vault;
    AdversarialDepositToken private token;
    address private alice;

    function setUp() public {
        alice = makeAddr("alice");
        vault = new InstitutionalTokenCustodyVault(address(this));
        vault.grantRole(COMPLIANCE_ROLE, address(this));
        vault.grantRole(POLICY_ROLE, address(this));
        vault.setInvestorAllowed(alice, true);

        token = new AdversarialDepositToken();
        token.mint(alice, INITIAL_FUNDS);
        _enableToken(address(token));

        vm.startPrank(alice);
        assertTrue(token.approve(address(vault), INITIAL_ALLOWANCE));
        vault.deposit(address(token), PREVIOUS_DEPOSIT);
        vm.stopPrank();
    }

    function testFalseReturnRollsBackTransferAndAccounting() public {
        _assertRejected(
            AdversarialDepositToken.TransferMode.ReturnFalse,
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token))
        );
    }

    function testTokenRevertPreservesExistingCredit() public {
        _assertRejected(
            AdversarialDepositToken.TransferMode.RevertAfterTransfer,
            abi.encodeWithSelector(AdversarialDepositToken.TransferRejected.selector)
        );
    }

    function testReceiverFeeRejectedAndRolledBack() public {
        _assertUnexpectedMovement(AdversarialDepositToken.TransferMode.ReceiverFee);
    }

    function testExtraSenderDebitRejectedAndRolledBack() public {
        _assertUnexpectedMovement(AdversarialDepositToken.TransferMode.SenderFee);
    }

    function testSuccessfulReturnWithoutMovementCannotCreateCredit() public {
        _assertUnexpectedMovement(AdversarialDepositToken.TransferMode.NoMovement);
    }

    function testIncreasingOwnerBalanceProducesMovementError() public {
        _assertUnexpectedMovement(AdversarialDepositToken.TransferMode.OwnerIncrease);
    }

    function testDecreasingVaultBalanceProducesMovementError() public {
        _assertUnexpectedMovement(AdversarialDepositToken.TransferMode.VaultDecrease);
    }

    function testExcessReceivedTokensRejectedAndRolledBack() public {
        _assertUnexpectedMovement(AdversarialDepositToken.TransferMode.ReceiverBonus);
    }

    function testExactTransferWithoutReturnDataIsAccepted() public {
        token.setMode(AdversarialDepositToken.TransferMode.NoReturn);
        uint256 previousEpoch = vault.policyEpoch();

        vm.prank(alice);
        vault.deposit(address(token), ATTEMPT);

        uint256 credited = PREVIOUS_DEPOSIT + ATTEMPT;
        assertEq(token.balanceOf(alice), INITIAL_FUNDS - credited);
        assertEq(token.balanceOf(address(vault)), credited);
        assertEq(token.allowance(alice, address(vault)), INITIAL_ALLOWANCE - credited);
        assertEq(token.totalSupply(), INITIAL_FUNDS);
        assertEq(vault.balanceOf(alice, address(token)), credited);
        assertEq(vault.totalLiability(address(token)), credited);
        assertEq(vault.policyEpoch(), previousEpoch);
    }

    function testCaughtReentrantDepositIsBlockedAndOuterDepositCreditsOnce() public {
        CallbackDepositToken callbackToken = _prepareCallbackToken();
        callbackToken.configureCallback(true, false);
        uint256 previousEpoch = vault.policyEpoch();

        vm.prank(alice);
        vault.deposit(address(callbackToken), ATTEMPT);

        assertEq(callbackToken.callbackAttempts(), 1);
        assertFalse(callbackToken.callbackSucceeded());
        assertEq(
            callbackToken.callbackError(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(callbackToken.balanceOf(alice), INITIAL_FUNDS - PREVIOUS_DEPOSIT - ATTEMPT);
        assertEq(callbackToken.balanceOf(address(vault)), PREVIOUS_DEPOSIT + ATTEMPT);
        assertEq(callbackToken.balanceOf(address(callbackToken)), callbackToken.OWN_FUNDS());
        assertEq(callbackToken.allowance(address(callbackToken), address(vault)), callbackToken.OWN_FUNDS());
        assertEq(vault.balanceOf(alice, address(callbackToken)), PREVIOUS_DEPOSIT + ATTEMPT);
        assertEq(vault.balanceOf(address(callbackToken), address(callbackToken)), 0);
        assertEq(vault.totalLiability(address(callbackToken)), PREVIOUS_DEPOSIT + ATTEMPT);
        assertEq(vault.policyEpoch(), previousEpoch);

        callbackToken.depositOwnTokens();

        uint256 ownDeposit = callbackToken.CALLBACK_AMOUNT();
        assertEq(vault.balanceOf(address(callbackToken), address(callbackToken)), ownDeposit);
        assertEq(vault.balanceOf(alice, address(callbackToken)), PREVIOUS_DEPOSIT + ATTEMPT);
        assertEq(vault.totalLiability(address(callbackToken)), PREVIOUS_DEPOSIT + ATTEMPT + ownDeposit);
        assertEq(callbackToken.balanceOf(address(vault)), PREVIOUS_DEPOSIT + ATTEMPT + ownDeposit);
        assertEq(callbackToken.balanceOf(address(callbackToken)), callbackToken.OWN_FUNDS() - ownDeposit);
        assertEq(callbackToken.callbackAttempts(), 1);
    }

    function testUncaughtReentrantDepositRevertsAtomicallyAndAllowsRetry() public {
        CallbackDepositToken callbackToken = _prepareCallbackToken();
        callbackToken.configureCallback(true, true);
        uint256 previousEpoch = vault.policyEpoch();

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        vault.deposit(address(callbackToken), ATTEMPT);

        assertEq(callbackToken.balanceOf(alice), INITIAL_FUNDS - PREVIOUS_DEPOSIT);
        assertEq(callbackToken.balanceOf(address(vault)), PREVIOUS_DEPOSIT);
        assertEq(callbackToken.balanceOf(address(callbackToken)), callbackToken.OWN_FUNDS());
        assertEq(callbackToken.allowance(alice, address(vault)), INITIAL_ALLOWANCE - PREVIOUS_DEPOSIT);
        assertEq(callbackToken.allowance(address(callbackToken), address(vault)), callbackToken.OWN_FUNDS());
        assertEq(callbackToken.totalSupply(), INITIAL_FUNDS + callbackToken.OWN_FUNDS());
        assertEq(vault.balanceOf(alice, address(callbackToken)), PREVIOUS_DEPOSIT);
        assertEq(vault.balanceOf(address(callbackToken), address(callbackToken)), 0);
        assertEq(vault.totalLiability(address(callbackToken)), PREVIOUS_DEPOSIT);
        assertEq(callbackToken.callbackAttempts(), 0);
        assertTrue(callbackToken.callbackEnabled());
        assertEq(vault.policyEpoch(), previousEpoch);

        callbackToken.configureCallback(false, false);
        vm.prank(alice);
        vault.deposit(address(callbackToken), ATTEMPT);

        assertEq(callbackToken.balanceOf(alice), INITIAL_FUNDS - PREVIOUS_DEPOSIT - ATTEMPT);
        assertEq(callbackToken.balanceOf(address(vault)), PREVIOUS_DEPOSIT + ATTEMPT);
        assertEq(vault.balanceOf(alice, address(callbackToken)), PREVIOUS_DEPOSIT + ATTEMPT);
        assertEq(vault.totalLiability(address(callbackToken)), PREVIOUS_DEPOSIT + ATTEMPT);
    }

    function _assertUnexpectedMovement(AdversarialDepositToken.TransferMode mode) private {
        _assertRejected(mode, abi.encodeWithSelector(InstitutionalTokenCustodyVault.UnexpectedTokenMovement.selector));
    }

    function _assertRejected(AdversarialDepositToken.TransferMode mode, bytes memory expectedError) private {
        token.setMode(mode);
        uint256 previousEpoch = vault.policyEpoch();

        vm.expectRevert(expectedError);
        vm.prank(alice);
        vault.deposit(address(token), ATTEMPT);

        assertEq(token.balanceOf(alice), INITIAL_FUNDS - PREVIOUS_DEPOSIT);
        assertEq(token.balanceOf(address(vault)), PREVIOUS_DEPOSIT);
        assertEq(token.allowance(alice, address(vault)), INITIAL_ALLOWANCE - PREVIOUS_DEPOSIT);
        assertEq(token.totalSupply(), INITIAL_FUNDS);
        assertEq(vault.balanceOf(alice, address(token)), PREVIOUS_DEPOSIT);
        assertEq(vault.totalLiability(address(token)), PREVIOUS_DEPOSIT);
        assertEq(vault.policyEpoch(), previousEpoch);
    }

    function _prepareCallbackToken() private returns (CallbackDepositToken callbackToken) {
        callbackToken = new CallbackDepositToken(vault);
        _enableToken(address(callbackToken));
        vault.setInvestorAllowed(address(callbackToken), true);
        callbackToken.mint(alice, INITIAL_FUNDS);

        vm.startPrank(alice);
        assertTrue(callbackToken.approve(address(vault), INITIAL_ALLOWANCE));
        vault.deposit(address(callbackToken), PREVIOUS_DEPOSIT);
        vm.stopPrank();
    }

    function _enableToken(address asset) private {
        InstitutionalTokenCustodyVault.TokenPolicy memory policy;
        policy.depositsEnabled = true;
        vault.setTokenPolicy(asset, policy);
    }
}
