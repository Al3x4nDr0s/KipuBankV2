# KipuBankV2 🏦

## Contrato Inteligente Bancario Multi-Token con Límite Dinámico

Este repositorio contiene la evolución del contrato original `KipuBank` a una versión robusta y lista para producción, denominada `KipuBankV2`.

El contrato ha sido refactorizado para soportar **múltiples tokens (ETH y ERC-20)**, integrar un **límite bancario global dinámico basado en USD** a través de **Chainlink Data Feeds**, e implementar mejores prácticas de arquitectura y seguridad, incluyendo control de acceso (`Ownable`) y manejo avanzado de errores (`Custom Errors`).

---

## 🚀 Mejoras Clave Implementadas

La versión `KipuBankV2` se distancia de su predecesor al introducir las siguientes funcionalidades críticas:

| Característica | Implementación | Ventaja Principal |
| :--- | :--- | :--- |
| **Soporte Multi-Token** | **`mapping(address => mapping(address => uint256))`** anidado. | Permite a los usuarios depositar y retirar cualquier token ERC-20 además del token nativo (ETH), usando `address(0)` para representar ETH. |
| **Límite Bancario Dinámico (USD)** | Integración con **Chainlink Data Feeds (ETH/USD)**. | El límite de depósito (`USD_BANK_CAP`) se mantiene estable en valor fiduciario (\$10,000,000 USD) y se convierte dinámicamente a Wei en tiempo real, protegiendo al banco de la volatilidad de ETH. |
| **Control de Acceso** | Herencia de **`Ownable`** (OpenZeppelin). | Restringe funciones de mantenimiento y emergencia (ej. `emergencyTokenWithdrawal`) al propietario del contrato, siguiendo el principio del menor privilegio. |
| **Seguridad y Gas** | Uso estricto de **Custom Errors**, `immutable` y patrón **Checks-Effects-Interactions**. | Mejora la legibilidad del *stack trace*, reduce el costo de gas en la reversión (Custom Errors), y garantiza la atomicidad de las transacciones. |

---

## 📐 Notas sobre Decisiones de Diseño (*Trade-offs*)

Al evolucionar el contrato, se tomaron decisiones de diseño conscientes para equilibrar la complejidad, el gas y la seguridad:

1.  **Contabilidad de Token Cruda:**
    * **Decisión:** Los saldos se almacenan en la unidad base de su token (ej., 18 decimales para ETH, 6 para USDC) sin normalización.
    * **Razón:** Evita la complejidad y posibles errores de redondeo o pérdida de precisión que ocurrirían al convertir constantemente tokens de alta precisión (18 decimales) a un estándar unificado (ej., 6 decimales).

2.  **Uso de Chainlink en Cada Depósito Nativo:**
    * **Decisión:** El cálculo de la conversión de `USD_BANK_CAP` a Wei se realiza dentro de la función `depositNative()`.
    * **Razón:** Proporciona la validación más actual y resistente a la manipulación contra el límite en USD.
    * **Costo:** Incrementa el costo de gas para cada depósito nativo. Este gasto es un **costo de seguridad** necesario.

3.  **Límite Bancario solo para ETH:**
    * **Decisión:** La lógica del límite bancario dinámico solo aplica al token nativo (ETH).
    * **Razón:** Implementar un límite bancario *único* para el valor total en USD de *todos* los tokens requeriría integrar múltiples oráculos (ej., USDC/USD, DAI/USD, etc.) y mantener una contabilidad sumatoria que sería significativamente más compleja y costosa en gas. Se prioriza asegurar el activo más volátil (ETH).

---

## 🛠️ Instrucciones de Despliegue e Interacción

### Requisitos

Para compilar y desplegar, necesitarás las bibliotecas de OpenZeppelin y Chainlink:

```bash
# Instalar dependencias de OpenZeppelin y Chainlink
npm install @openzeppelin/contracts @chainlink/contracts
