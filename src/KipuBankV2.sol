// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

//import "@openzeppelin/contracts/access/Ownable.sol";
//import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol"; // Interfaz de Chainlink

/// @title KipuBankV2
/// @author Alejandro Cardenas
/// @notice Un banco avanzado que soporta depósitos y retiros de ETH y cualquier token ERC-20,
/// @notice con un límite de depósito dinámico controlado por Chainlink Data Feeds.
contract KipuBankV2 is Ownable {

    /*///////////////////////////////////////////////////////////////
                              STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    // Constantes
    /// @notice El límite global de depósito del banco, fijado en USD (por ejemplo, $10,000,000 con 6 decimales).
    uint256 public constant USD_BANK_CAP = 10_000_000e6; // $10M, asumiendo 6 decimales para coherencia con oráculos comunes. 
    
    // Variables Inmutables
    /// @notice La dirección del Data Feed de Chainlink para el par ETH/USD. [cite: 89]
    AggregatorV3Interface private immutable s_priceFeed;
    /// @notice El máximo permitido a retirar por transacción (en Wei para ETH, o en la unidad base del ERC-20). [cite: 6]
    uint256 public immutable transactionWithdrawalCap;

    // Contabilidad Multi-token (Mapping Anidado)
    /// @notice Mapping anidado de direcciones de usuario a direcciones de token, a su saldo (en la unidad base del token).
    /// @dev address(0) se usa para representar el token nativo (ETH). [cite: 77, 91]
    mapping(address => mapping(address => uint256)) private userVaults; // 

    // ... (TotalDeposits y TotalWithdrawals se mantienen) ...

    /*///////////////////////////////////////////////////////////////
                           CUSTOM ERRORS (Se mantienen los originales y se añaden, si es necesario)
    //////////////////////////////////////////////////////////////*/
    
    error InvalidToken();
    // ...

    /*///////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _priceFeedAddress Dirección del Chainlink ETH/USD Data Feed.
    /// @param _transactionWithdrawalCap Límite de retiro por transacción.
    constructor(
        address _priceFeedAddress,
        uint256 _transactionWithdrawalCap
    ) Ownable(msg.sender) { // Inicializa Ownable con el desplegador como Owner. 
        require(_priceFeedAddress != address(0), "Invalid price feed address");
        s_priceFeed = AggregatorV3Interface(_priceFeedAddress);
        transactionWithdrawalCap = _transactionWithdrawalCap;
    }

    /*///////////////////////////////////////////////////////////////
                            FUNCIONES DE VISUALIZACIÓN
    //////////////////////////////////////////////////////////////*/

    /// @notice Obtiene el saldo del usuario para un token específico. [cite: 52]
    /// @param _user La dirección del usuario.
    /// @param _token La dirección del token (address(0) para ETH).
    /// @return El saldo del usuario.
    function getBalance(address _user, address _token) external view returns (uint256) {
        return userVaults[_user][_token];
    }

    /*///////////////////////////////////////////////////////////////
                            FUNCIONES AUXILIARES
    //////////////////////////////////////////////////////////////*/

    /// @notice Obtiene el precio actual de ETH/USD del oráculo de Chainlink. 
    /// @return El precio de ETH/USD.
    function _getLatestPrice() private view returns (int256) {
        (
            ,
            int256 price, // El valor del precio
            ,
            ,
        ) = s_priceFeed.latestRoundData();
        // Nota: El precio se devuelve con 8 decimales, según el contrato de Chainlink.
        return price;
    }

    /// @notice Convierte el USD_BANK_CAP (con 6 decimales) a Wei, basado en el precio ETH/USD. [cite: 79, 92]
    /// @dev Maneja la conversión de decimales entre el CAP (6 dec) y el Oráculo (8 dec) y ETH (18 dec).
    /// @return El límite bancario en Wei (18 decimales).
    function _convertUSDCapToWei() private view returns (uint256) {
        int256 ethUsdPrice = _getLatestPrice(); // 8 decimales
        require(ethUsdPrice > 0, "Price feed returned non-positive value");
        
        // Fórmula de Conversión:
        // Cap en Wei = (CAP_USD * 10^18) / (Precio_ETH_USD * 10^(18 - OraculoDec))
        // Dado que USD_BANK_CAP tiene 6 decimales, es:
        // Wei = (USD_BANK_CAP / 10^6) * 10^18 / (Price_ETH_USD / 10^8)
        // Simplificado:
        // Wei = (USD_BANK_CAP * 10^20) / Price_ETH_USD
        
        // USD_BANK_CAP tiene 6 decimales, así que se escala por 10^18/10^6 = 10^12
        // El precio tiene 8 decimales.

        // Escalar el USD_BANK_CAP para que la multiplicación sea primero.
        uint256 capWeiNumerator = USD_BANK_CAP * 10**(18 - 6); // Cap en USD con 18 decimales (escalado)
        
        // Convertir el precio de int256 a uint256 y escalar para tener 18 decimales
        uint256 priceScaled = uint256(ethUsdPrice) * 10**(18 - 8); // Precio en USD con 18 decimales (escalado)
        
        // Resultado final en Wei (18 decimales)
        return capWeiNumerator / priceScaled; 
    }

    /*///////////////////////////////////////////////////////////////
                            FUNCIONES TRANSACCIONALES
    //////////////////////////////////////////////////////////////*/

    /// @notice Permite a los usuarios depositar ETH en su bóveda. [cite: 29, 30]
    function depositETH() external payable {
        // ... (Revisión de ZeroAmount y otros checks)
        
        // CHECK: Límite Bancario Dinámico (Solo aplica a ETH, ya que la contabilidad total es más compleja)
        uint256 currentCapInWei = _convertUSDCapToWei();
        uint256 futureContractBalance = address(this).balance + msg.value; // Balance del contrato después del depósito
        
        if (futureContractBalance > currentCapInWei) {
             // Usar un error nuevo para el cap dinámico si se prefiere, o el existente
            revert DepositExceedsBankCap(msg.value, address(this).balance, currentCapInWei); // [cite: 32]
        }

        // EFFECTS
        userVaults[msg.sender][address(0)] += msg.value; // ETH depositado
        // ... (Actualización de totalDeposits y Evento)
    }

    /// @notice Permite a los usuarios depositar tokens ERC-20. 
    /// @param _token La dirección del token ERC-20.
    /// @param _amount La cantidad de token a depositar.
    function depositERC20(address _token, uint256 _amount) external {
        require(_token != address(0), "Use depositETH for native token"); // No permitir address(0) aquí
        require(_amount > 0, "Zero amount deposit not allowed");
        // ... (Lógica de seguridad, ej. si el token está en una lista blanca)

        // INTERACTIONS (Transferencia de token del usuario al contrato)
        // Se requiere que el usuario haya aprobado previamente el contrato.
        // Se usaría la interfaz de ERC-20 para llamar a transferFrom.
        // IERC20(_token).transferFrom(msg.sender, address(this), _amount);

        // EFFECTS (Actualización de estado)
        userVaults[msg.sender][_token] += _amount;
        // ... (Evento)
    }

    /// @notice Permite a los usuarios retirar tokens (ETH o ERC-20). 
    /// @param _token La dirección del token a retirar (address(0) para ETH).
    /// @param _amount La cantidad a retirar.
    function withdraw(address _token, uint256 _amount) external {
        // CHECKS (Withdrawal Cap y Balance) [cite: 42, 44]
        if (_amount > transactionWithdrawalCap) {
             revert WithdrawalExceedsCap(_amount, transactionWithdrawalCap);
        }
        uint256 userBalance = userVaults[msg.sender][_token];
        if (_amount > userBalance) {
             revert InsufficientBalance(_amount, userBalance);
        }

        // EFFECTS (Actualizar estado ANTES de la interacción) [cite: 46]
        userVaults[msg.sender][_token] = userBalance - _amount; 

        // INTERACTIONS (Transferencia de token o ETH)
        if (_token == address(0)) {
            // Retiro de ETH (Token nativo)
            (bool success, ) = payable(msg.sender).call{value: _amount}(""); // [cite: 49]
            if (!success) revert TransferFailed(); // [cite: 50]
        } else {
            // Retiro de ERC-20
            // Se usaría la interfaz de ERC-20 para llamar a transfer.
            // IERC20(_token).transfer(msg.sender, _amount);
        }
        // ... (Actualización de totalWithdrawals y Evento)
    }
}