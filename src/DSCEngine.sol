// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DSCEngine
 * @author Peace Oghenevwefe
 * @notice This contract is the core of the Decentralized Stable Coin (DSC) system.
 * It manages the minting and burning of the DSC token, collateral management, and stability mechanisms.
 * @dev This contract is designed to be used with the DecentralizedStableCoin (DSC) token contract.
 * It interacts with the DSC token to mint and burn tokens based on collateral deposits and withdrawals.
 * The contract also implements various stability mechanisms to maintain the value of the DSC token
 * relative to a target value, such as the US dollar.
 * Our DSC system should always be "overcollateralized". At no point should the value of all collateral be <= the $ backed value of all the DSC tokens in circulation.
 * The contract is designed to be modular and extensible, allowing for future enhancements and additional features
 * to be added without disrupting the existing functionality.
 * it is algorithmically stable and uses collateral to back the value of the DSC token.
 */
contract DSCEngine is ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                Errors
    //////////////////////////////////////////////////////////////*/
    error DSCEngine_TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine_TokenNotAllowed();
    error DSCEngine_AmountMustBeGreaterThanZero();
    error DSCEngine_TransferFailed();

    /*//////////////////////////////////////////////////////////////
                                State Variables
    //////////////////////////////////////////////////////////////*/
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;

    DecentralizedStableCoin private immutable i_dsc;

    /*//////////////////////////////////////////////////////////////
                                Events
    //////////////////////////////////////////////////////////////*/
    event CallateralDeposited(address indexed user, address indexed tokenCollateralAddress, uint256 amountOfCollateral);

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine_AmountMustBeGreaterThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine_TokenNotAllowed();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                Functions
    //////////////////////////////////////////////////////////////*/
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine_TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /*//////////////////////////////////////////////////////////////
                                External Functions
    //////////////////////////////////////////////////////////////*/
    function depositCollateralAndMintDsc() external {}

    /**
     *
     * @param tokenCollateralAddress The address of the collateral token contract.
     * @param amountOfCollateral The amount of collateral to be deposited.
     * @dev This function allows users to deposit collateral into the DSCEngine.
     * It requires the address of the collateral token contract and the amount of collateral to be deposited.
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountOfCollateral)
        external
        moreThanZero(amountOfCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountOfCollateral;
        emit CallateralDeposited(msg.sender, tokenCollateralAddress, amountOfCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountOfCollateral);

        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }

    function reedemCollateralForDsc() external {}

    function reedemCollateral() external {}

    function mintDsc() external {}

    function burnDsc() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}
}
