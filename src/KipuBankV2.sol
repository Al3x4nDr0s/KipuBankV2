// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/// @title KipuBankV2
/// @author Alejandro Cardenas
/// @notice An advanced bank contract supporting deposits and withdrawals of native tokens (ETH) and ERC-20 tokens.
/// @notice It features a dynamic deposit limit (in $USD) controlled by Chainlink Data Feeds.
contract KipuBankV2 is Ownable {

    /*///////////////////////////////////////////////////////////////
                           TYPES AND CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev address(0) is used to represent the native token (ETH).
    address private constant NATIVE_TOKEN = address(0);

    /// @notice The global deposit limit for the bank, fixed in USD (e.g., $10,000,000 with 6 decimals).
    /// @dev We use 6 decimals for the internal USD cap to align with stablecoin standards (e.g., USDC).
    uint256 public constant USD_BANK_CAP = 10_000_000e6; // $10,000,000 * 10^6

    /// @notice The number of decimals used for our USD bank cap.
    uint8 public constant USD_CAP_DECIMALS = 6;

    /*///////////////////////////////////////////////////////////////
                              STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The address of the Chainlink Data Feed for the ETH/USD pair.
    AggregatorV3Interface private immutable s_priceFeed;

    /// @notice The maximum amount allowed to be withdrawn per transaction (in the token's base unit).
    /// @dev This cap applies to all supported tokens.
    uint256 public immutable transactionWithdrawalCap;

    /// @notice Nested mapping from user address -> token address -> balance (in token's base unit).
    /// @dev NATIVE_TOKEN (address(0)) is used for ETH.
    mapping(address => mapping(address => uint256)) private userVaults;

    /// @notice Total count of successful deposits made.
    uint256 public totalDeposits;

    /// @notice Total count of successful withdrawals made.
    uint256 public totalWithdrawals;

    /*///////////////////////////////////////////////////////////////
                           CUSTOM ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a deposit exceeds the established global bank cap (in Wei/Token Base Unit).
    error DepositExceedsBankCap(uint256 depositAmount, uint256 currentContractBalance, uint256 currentCap);

    /// @notice Emitted when the user's balance is insufficient for the requested withdrawal.
    error InsufficientBalance(uint256 requestedAmount, uint256 userBalance);

    /// @notice Emitted when a withdrawal exceeds the per-transaction limit.
    error WithdrawalExceedsCap(uint256 requestedAmount, uint256 transactionWithdrawalCap);
    
    /// @notice Emitted when the transfer of Ether or Token fails during a withdrawal.
    error TransferFailed();

    /// @notice Emitted when a zero amount is deposited or withdrawn.
    error ZeroAmount();

    /// @notice Emitted when an ERC20 deposit is attempted using the native function, or vice-versa.
    error InvalidTokenFunction();
    
    /// @notice Emitted when Chainlink or other critical calculations fail.
    error CalculationFailed();
    
    /*///////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a user successfully deposits funds.
    /// @param depositor The address that made the deposit.
    /// @param token The address of the token deposited (address(0) for ETH).
    /// @param amount The amount deposited.
    /// @param newBalance The user's new balance.
    event DepositMade(address indexed depositor, address indexed token, uint256 amount, uint256 newBalance);

    /// @notice Emitted when a user successfully withdraws funds.
    /// @param withdrawer The address that performed the withdrawal.
    /// @param token The address of the token withdrawn (address(0) for ETH).
    /// @param amount The amount withdrawn.
    /// @param newBalance The user's new balance.
    event WithdrawalMade(address indexed withdrawer, address indexed token, uint256 amount, uint256 newBalance);

    /*///////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @dev Initializes the contract with the required price feed and withdrawal cap. Implements Ownable.
    /// @param _priceFeedAddress The address of the Chainlink ETH/USD Data Feed.
    /// @param _transactionWithdrawalCap The maximum withdrawal amount per transaction.
    constructor(
        address _priceFeedAddress,
        uint256 _transactionWithdrawalCap
    ) Ownable(msg.sender) { // Initializes Ownable with the deployer as the Owner
        if (_priceFeedAddress == address(0)) revert CalculationFailed(); 
        s_priceFeed = AggregatorV3Interface(_priceFeedAddress);
        transactionWithdrawalCap = _transactionWithdrawalCap; // Set immutable variable
    }

    /*///////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Gets the vault balance of a specific user for a given token.
    /// @param _user The address of the user.
    /// @param _token The address of the token (NATIVE_TOKEN for ETH).
    /// @return The user's current balance (in the token's base unit).
    function getBalance(address _user, address _token) external view returns (uint256) {
        return userVaults[_user][_token];
    }

    /// @notice Returns the current dynamic bank cap in the native token's base unit (Wei).
    /// @return The current global bank cap in Wei.
    function getCurrentBankCapInWei() public view returns (uint256) {
        return _convertUSDCapToTokenBaseUnit(s_priceFeed, NATIVE_TOKEN);
    }

    /*///////////////////////////////////////////////////////////////
                            HELPER AND CONVERSION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Converts the fixed USD_BANK_CAP to the native token's base unit (Wei) using the Chainlink oracle.
    /// @dev This function handles all decimal conversions for safety.
    /// @param _priceFeed The price oracle for the pair (e.g., ETH/USD).
    /// @param _token The address of the token (must be NATIVE_TOKEN for this logic).
    /// @return The calculated bank cap in the token's base unit (Wei).
    function _convertUSDCapToTokenBaseUnit(
        AggregatorV3Interface _priceFeed,
        address _token
    ) private view returns (uint256) {
        // This complex logic only applies to the native token cap
        if (_token != NATIVE_TOKEN) revert CalculationFailed();

        // 1. Get the price of ETH/USD from the oracle
        (
            ,
            int256 price, // The price (e.g., 1500 * 10^8 if the price is 1500.00)
            ,
            ,
        ) = _priceFeed.latestRoundData();

        if (price <= 0) revert CalculationFailed(); 
        
        // Standard Chainlink ETH/USD feeds use 8 decimals.
        uint8 priceFeedDecimals = 8; 
        uint8 tokenDecimals = 18; // ETH decimals

        // 2. Scale the price and the CAP for safe division:
        // Formula: Wei = (USD_BANK_CAP * 10^(TokenDecimals + PriceFeedDecimals - CapDecimals)) / Price
        // In this case: Wei = (USD_BANK_CAP * 10^(18 + 8 - 6)) / Price
        // Wei = (USD_BANK_CAP * 10^20) / Price

        uint256 priceUint = uint256(price);
        
        // Calculate the scale factor (18 + 8 - 6 = 20)
        uint256 scaleFactor = (tokenDecimals + priceFeedDecimals) - USD_CAP_DECIMALS;

        // Scale the numerator. Using unchecked for known-safe constant arithmetic.
        uint256 capWeiNumerator;
        unchecked {
            capWeiNumerator = USD_BANK_CAP * (10 ** scaleFactor); 
        }

        // 3. Final result in the base unit (Wei)
        return capWeiNumerator / priceUint; 
    }

    /*///////////////////////////////////////////////////////////////
                            PUBLIC TRANSACTIONAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Allows users to deposit native token (ETH) into their personal vault.
    function depositNative() external payable {
        if (msg.value == 0) revert ZeroAmount();
        
        // CHECK: Dynamic Bank Cap (Applies only to the native token for simplicity)
        uint256 currentCapInWei = getCurrentBankCapInWei();
        uint256 futureContractBalance = address(this).balance + msg.value;

        if (futureContractBalance > currentCapInWei) {
            revert DepositExceedsBankCap(msg.value, address(this).balance, currentCapInWei);
        }

        // EFFECTS: (Update state BEFORE any external interaction)
        // Nested mapping: userVaults[msg.sender][NATIVE_TOKEN]
        userVaults[msg.sender][NATIVE_TOKEN] += msg.value;
        
        unchecked { 
            totalDeposits++;
        }

        // Emit Event
        emit DepositMade(msg.sender, NATIVE_TOKEN, msg.value, userVaults[msg.sender][NATIVE_TOKEN]);
    }

    /// @notice Allows users to deposit ERC-20 tokens.
    /// @dev Users must approve the contract to spend the token beforehand.
    /// @param _token The address of the ERC-20 token.
    /// @param _amount The amount of token to deposit.
    function depositERC20(address _token, uint256 _amount) external {
        if (_token == NATIVE_TOKEN) revert InvalidTokenFunction(); // Use depositNative
        if (_amount == 0) revert ZeroAmount();

        // EFFECTS (Update state BEFORE interaction)
        userVaults[msg.sender][_token] += _amount;
        
        unchecked {
            totalDeposits++;
        }

        // INTERACTIONS (Transfer token from user to contract)
        // Checks-Effects-Interactions pattern
        if (!IERC20(_token).transferFrom(msg.sender, address(this), _amount)) {
            revert TransferFailed();
        }

        // Emit Event
        emit DepositMade(msg.sender, _token, _amount, userVaults[msg.sender][_token]);
    }

    /// @notice Allows users to withdraw tokens (ETH or ERC-20).
    /// @param _token The address of the token to withdraw (NATIVE_TOKEN for ETH).
    /// @param _amount The amount to withdraw.
    function withdraw(address _token, uint256 _amount) external {
        // CHECKS
        if (_amount == 0) revert ZeroAmount();
        if (_amount > transactionWithdrawalCap) {
             revert WithdrawalExceedsCap(_amount, transactionWithdrawalCap); // Per-transaction limit
        }
        
        // Insufficient balance check
        uint256 userBalance = userVaults[msg.sender][_token];
        if (_amount > userBalance) {
             revert InsufficientBalance(_amount, userBalance); 
        }

        // EFFECTS (Update state BEFORE interaction)
        userVaults[msg.sender][_token] = userBalance - _amount; 

        unchecked {
            totalWithdrawals++;
        }

        // INTERACTIONS (Transfer)
        bool success;
        if (_token == NATIVE_TOKEN) {
            // Native Token (ETH): Use call for secure transfer
            (success, ) = payable(msg.sender).call{value: _amount}(""); 
        } else {
            // ERC-20 Token: Use transfer
            success = IERC20(_token).transfer(msg.sender, _amount);
        }

        if (!success) {
            revert TransferFailed(); // Revert state change if interaction fails.
        }

        // Emit Event
        emit WithdrawalMade(msg.sender, _token, _amount, userVaults[msg.sender][_token]);
    }
    
    /*///////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS (OWNER ONLY)
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Allows the Owner to withdraw accidentally sent ERC20 tokens (e.g., tokens not supported by the bank).
    /// @dev This function is for recovery and should NOT be used for native token (ETH) or supported ERC20 tokens.
    /// @param _token The address of the stuck ERC20 token.
    /// @param _amount The amount to withdraw.
    function emergencyTokenWithdrawal(address _token, uint256 _amount) external onlyOwner {
        if (_token == NATIVE_TOKEN) revert InvalidTokenFunction();
        if (_amount == 0) revert ZeroAmount();

        if (!IERC20(_token).transfer(owner(), _amount)) {
            revert TransferFailed();
        }
    }
}
