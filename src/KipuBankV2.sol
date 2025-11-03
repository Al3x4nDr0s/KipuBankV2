// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title KipuBankV2
/// @author Alejandro Cardenas
/// @notice A decentralized banking smart contract that allows users to deposit and withdraw ETH or ERC20 tokens.
/// @dev Includes reentrancy protection, validation via modifiers, and gas-optimized state handling.

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract KipuBankV2 is Ownable, ReentrancyGuard {
   /*///////////////////////////////////////////////////////////////
                           TYPES AND CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Address used to represent native ETH deposits.
    address public constant NATIVE_TOKEN = address(0);

    /// @notice Global USD deposit cap (expressed with 6 decimals).
    uint256 public constant USD_BANK_CAP = 10_000_000 * (10 ** 6);

    /// @notice Number of decimals used for USD cap.
    uint8 public constant USD_CAP_DECIMALS = 6;

    /*///////////////////////////////////////////////////////////////
                              STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Chainlink ETH/USD price feed.
    AggregatorV3Interface public immutable priceFeed;

    /// @notice Maximum amount allowed per withdrawal transaction.
    uint256 public transactionWithdrawalCap;

    /// @notice Mapping of user balances by token.
    mapping(address => mapping(address => uint256)) private userVaults;

    /// @notice Total ETH deposits in the bank (in wei).
    uint256 public totalDeposits;

    /*///////////////////////////////////////////////////////////////
                           CUSTOM ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @custom:error ZeroAmount Thrown when a zero amount is provided.
    error ZeroAmount();

    /// @custom:error TransferFailed Thrown when a token or ETH transfer fails.
    error TransferFailed();

    /// @custom:error InsufficientBalance Thrown when user balance is too low.
    error InsufficientBalance();

    /// @custom:error ExceedsBankCap Thrown when ETH deposit exceeds USD-based cap.
    error ExceedsBankCap(uint256 attempted, uint256 cap);

    /// @custom:error ExceedsWithdrawalCap Thrown when withdrawal exceeds transaction cap.
    error ExceedsWithdrawalCap(uint256 attempted, uint256 cap);

    /// @custom:error InvalidTokenFunction Thrown when an invalid token function is used.
    error InvalidTokenFunction();

    /// @custom:error CalculationFailed Thrown when oracle calculation fails (e.g., invalid price).
    error CalculationFailed();

    /*///////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @custom:event DepositMade
    /// @notice Emitted when a user deposits ETH or ERC20 tokens.
    event DepositMade(address indexed depositor, address indexed token, uint256 amount, uint256 newBalance);

    /// @custom:event WithdrawalMade
    /// @notice Emitted when a user withdraws ETH or ERC20 tokens.
    event WithdrawalMade(address indexed withdrawer, address indexed token, uint256 amount, uint256 newBalance);

    /// @custom:event TransactionWithdrawalCapUpdated
    /// @notice Emitted when the owner updates the per-transaction withdrawal cap.
    event TransactionWithdrawalCapUpdated(uint256 newCap);

    /*///////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the contract with Chainlink price feed and withdrawal cap.
     * @param _priceFeedAddress Chainlink ETH/USD feed address.
     * @param _transactionWithdrawalCap Maximum allowed withdrawal per transaction.
     */
    constructor(address _priceFeedAddress, uint256 _transactionWithdrawalCap) Ownable(msg.sender) {
        require(_priceFeedAddress != address(0), "priceFeed 0");
        priceFeed = AggregatorV3Interface(_priceFeedAddress);
        transactionWithdrawalCap = _transactionWithdrawalCap;
    }

    /*///////////////////////////////////////////////////////////////
                                 MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Ensures that a nonzero amount is provided.
    modifier nonZeroAmount(uint256 _amount) {
        if (_amount == 0) revert ZeroAmount();
        _;
    }

    /// @dev Validates a deposit, enforcing USD-based cap for native ETH.
    modifier validateDeposit(address _token, uint256 _amount) {
        if (_amount == 0) revert ZeroAmount();
        if (_token == NATIVE_TOKEN) {
            uint256 capWei = _ethBankCapWei();
            uint256 newTotal = totalDeposits + _amount;
            if (newTotal > capWei) revert ExceedsBankCap(newTotal, capWei);
        }
        _;
    }

    /// @dev Validates a withdrawal against zero and transaction-level caps.
    modifier validateWithdrawal(uint256 _amount) {
        if (_amount == 0) revert ZeroAmount();
        if (_amount > transactionWithdrawalCap) revert ExceedsWithdrawalCap(_amount, transactionWithdrawalCap);
        _;
    }

   /*///////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the user's current token balance.
     * @param _user The user's address.
     * @param _token The token address (use address(0) for ETH).
     * @return The current user balance for that token.
     */
    function getUserBalance(address _user, address _token) external view returns (uint256) {
        return userVaults[_user][_token];
    }

    /**
     * @notice Calculates the ETH cap in wei based on USD cap and Chainlink price feed.
     * @dev Assumes ETH/USD oracle with 8 decimals (standard Chainlink format).
     * @return capWei The maximum ETH amount allowed in the contract.
     */
    function _ethBankCapWei() internal view returns (uint256 capWei) {
        (, int256 price,, ,) = priceFeed.latestRoundData();
        if (price <= 0) revert CalculationFailed();
        uint8 priceFeedDecimals = 8;
        uint8 tokenDecimals = 18;
        uint256 scaleFactor = uint256(tokenDecimals + priceFeedDecimals - USD_CAP_DECIMALS);
        uint256 numerator = USD_BANK_CAP * (10 ** scaleFactor);
        capWei = numerator / uint256(price);
    }

    /*///////////////////////////////////////////////////////////////
                          MAIN TRANSACTIONAL FUNCTIONS
    /*///////////////////////////////////////////////////////////////

    /**
     * @notice Allows users to deposit native ETH.
     * @dev Enforces USD cap via Chainlink price feed.
     */
    function depositNative() external payable nonReentrant validateDeposit(NATIVE_TOKEN, msg.value) {
        _deposit(msg.sender, NATIVE_TOKEN, msg.value);
    }

    /**
     * @notice Allows users to deposit ERC20 tokens after approval.
     * @param _token The ERC20 token address.
     * @param _amount The amount to deposit.
     */
    function depositERC20(address _token, uint256 _amount) external nonReentrant validateDeposit(_token, _amount) {
        if (_token == NATIVE_TOKEN) revert InvalidTokenFunction();
        bool ok = IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        if (!ok) revert TransferFailed();
        _deposit(msg.sender, _token, _amount);
    }

    /**
     * @dev Internal function to record deposits, avoiding duplicated logic.
     * @param _user User making the deposit.
     * @param _token Token address (use address(0) for ETH).
     * @param _amount Amount to deposit.
     */
    function _deposit(address _user, address _token, uint256 _amount) internal {
        uint256 oldBalance = userVaults[_user][_token];
        uint256 newBalance = oldBalance + _amount;
        userVaults[_user][_token] = newBalance;

        if (_token == NATIVE_TOKEN) totalDeposits += _amount;

        emit DepositMade(_user, _token, _amount, newBalance);
    }

    /**
     * @notice Withdraws ETH or ERC20 tokens from user’s vault.
     * @param _token Token address (use address(0) for ETH).
     * @param _amount Amount to withdraw.
     */
    function withdraw(address _token, uint256 _amount) external nonReentrant validateWithdrawal(_amount) {
        uint256 userBalance = userVaults[msg.sender][_token];
        if (_amount > userBalance) revert InsufficientBalance();

        uint256 newBalance = userBalance - _amount;
        userVaults[msg.sender][_token] = newBalance;

        if (_token == NATIVE_TOKEN) {
            totalDeposits -= _amount;
            (bool success, ) = payable(msg.sender).call{value: _amount}("");
            if (!success) revert TransferFailed();
        } else {
            bool success = IERC20(_token).transfer(msg.sender, _amount);
            if (!success) revert TransferFailed();
        }

        emit WithdrawalMade(msg.sender, _token, _amount, newBalance);
    }

    /*///////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS (OWNER ONLY)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Allows the owner to recover mistakenly sent ERC20 tokens.
     * @param _token ERC20 token address.
     * @param _amount Amount to recover.
     */
    function emergencyTokenWithdrawal(address _token, uint256 _amount) external onlyOwner {
        if (_token == NATIVE_TOKEN) revert InvalidTokenFunction();
        if (_amount == 0) revert ZeroAmount();
        bool ok = IERC20(_token).transfer(owner(), _amount);
        if (!ok) revert TransferFailed();
    }

    /**
     * @notice Updates the withdrawal cap per transaction.
     * @param _newCap The new withdrawal cap.
     */
    function setTransactionWithdrawalCap(uint256 _newCap) external onlyOwner {
        transactionWithdrawalCap = _newCap;
        emit TransactionWithdrawalCapUpdated(_newCap);
    }

    /*///////////////////////////////////////////////////////////////
                                 FALLBACK
    /*///////////////////////////////////////////////////////////////

    /// @notice Prevents accidental ETH transfers outside depositNative().
    receive() external payable {
        revert("Use depositNative()");
    }
}
