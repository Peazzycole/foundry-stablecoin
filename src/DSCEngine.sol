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

pragma solidity ^0.8.20;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

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
    error DSCEngine_BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine_MintFailed();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    /*//////////////////////////////////////////////////////////////
                            State Variables
    //////////////////////////////////////////////////////////////*/
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 50% liquidation threshold
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // This means you get assets at a 10% discount when liquidating

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; // // Mapping of users to their collateral deposits
    mapping(address user => uint256 amount) private s_dscMinted; // Mapping of users to the amount of DSC they have minted
    address[] private s_collateralTokens; // List of collateral tokens accepted by the DSCEngine

    DecentralizedStableCoin private immutable i_dsc;

    /*//////////////////////////////////////////////////////////////
                                Events
    //////////////////////////////////////////////////////////////*/
    event CallateralDeposited(
        address indexed user, address indexed tokenCollateralAddress, uint256 indexed amountOfCollateral
    );
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount); // if
        // redeemFrom != redeemedTo, then it was liquidated

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
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /*//////////////////////////////////////////////////////////////
                                External Functions
    //////////////////////////////////////////////////////////////*/

    /**
     *
     * @param tokenCollateralAddress The address of the collateral token contract.
     * @param amountOfCollateral The amount of collateral to be deposited.
     * @param amountDscToMint The amount of DSC tokens to mint.
     * @dev This function allows users to deposit collateral and mint DSC tokens in a single transaction.
     * It requires the address of the collateral token contract, the amount of collateral to be deposited,
     * and the amount of DSC tokens to be minted.
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountOfCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountOfCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     *
     * @param tokenCollateralAddress The address of the collateral token contract.
     * @param amountOfCollateral The amount of collateral to be deposited.
     * @dev This function allows users to deposit collateral into the DSCEngine.
     * It requires the address of the collateral token contract and the amount of collateral to be deposited.
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountOfCollateral)
        public
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

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're withdrawing
     * @param amountCollateral: The amount of collateral you're withdrawing
     * @param amountDscToBurn: The amount of DSC you want to burn
     * @notice This function will withdraw your collateral and burn DSC in one transaction
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
    {
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice This function allows users to redeem their collateral.
     * @param tokenCollateralAddress The address of the collateral token contract.
     * @param amountCollateral The amount of collateral to be redeemed.
     * @dev This function allows users to redeem their collateral by specifying the token address and the amount.
     * It checks that the amount is greater than zero and that the token is allowed.
     * The function also ensures that the user's health factor remains above the minimum threshold after redemption.
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        nonReentrant
        isAllowedToken(tokenCollateralAddress)
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     *
     * @param amountDscToMint The amount of DSC tokens to mint.
     * @dev This function allows users to mint DSC tokens by depositing collateral.
     * It requires the amount of DSC tokens to be minted.
     * The function checks that the amount to mint is greater than zero and that the user has
     * @notice They must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);

        if (!minted) {
            revert DSCEngine_MintFailed();
        }
    }

    /*
     * @notice careful! You'll burn your DSC here! Make sure you want to do this...
     * @dev you might want to use this if you're nervous you might get liquidated and want to just burn
     * your DSC but keep your collateral in.
     */
    function burnDsc(uint256 amount) external moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I don't think this would ever hit...
    }

    /**
     * @notice This function allows users to liquidate a position by covering the debt of another user.
     * @param collateral The address of the collateral token contract.
     * @param user The address of the user whose position is being liquidated.
     * @param debtToCover The amount of debt to cover in DSC tokens.
     * @dev This function allows users to liquidate a position by covering the debt of another user.
     * It requires the address of the collateral token, the user whose position is being liquidated,
     * and the amount of debt to cover in DSC tokens.
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        isAllowedToken(collateral)
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        _redeemCollateral(collateral, tokenAmountFromDebtCovered + bonusCollateral, user, msg.sender);
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);

        // This conditional should never hit, but just in case
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_dscMinted[onBehalfOf] -= amountDscToBurn;

        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        // This conditional is hypothetically unreachable
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    /*//////////////////////////////////////////////////////////////
                        Private and Internal Functions
    //////////////////////////////////////////////////////////////*/
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_dscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     *
     * @param user The address of the user for whom to calculate the health factor.
     * @return The health factor of the user.
     * @dev This function calculates the health factor for a given user.
     * The health factor is a measure of the user's collateralization ratio,
     * which is the ratio of the value of the user's collateral to the value of the DSC tokens they have minted.
     * A health factor greater than 1 indicates that the user is overcollateralized,
     * while a health factor less than 1 indicates that the user is undercollateralized.
     * The health factor is calculated as the total value of collateral divided by the total value of DSC tokens minted by the user.
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collatteralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        return (collatteralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine_BreaksHealthFactor(userHealthFactor);
        }
    }

    /*//////////////////////////////////////////////////////////////
                Public and External View Functions
    //////////////////////////////////////////////////////////////*/
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }
}
