// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uma/core/contracts/common/implementation/AddressWhitelist.sol";
import "@uma/core/contracts/common/implementation/ExpandedERC20.sol";
import "@uma/core/contracts/data-verification-mechanism/implementation/Constants.sol";
import "@uma/core/contracts/data-verification-mechanism/interfaces/FinderInterface.sol";
import "@uma/core/contracts/optimistic-oracle-v3/implementation/ClaimData.sol";
import "@uma/core/contracts/optimistic-oracle-v3/interfaces/OptimisticOracleV3Interface.sol";
import "@uma/core/contracts/optimistic-oracle-v3/interfaces/OptimisticOracleV3CallbackRecipientInterface.sol";

contract PredictionMarket is OptimisticOracleV3CallbackRecipientInterface {
    using SafeERC20 for IERC20;

    struct Market {
        bool resolved;
        bytes32 assertedOutcomeId;
        ExpandedIERC20 outcome1Token;
        ExpandedIERC20 outcome2Token;
        uint256 reward;
        uint256 requiredBond;
        bytes outcome1;
        bytes outcome2;
        bytes description;
        uint256 outcome1Pool;
        uint256 outcome2Pool;
    }

    struct AssertedMarket {
        address asserter;
        bytes32 marketId;
    }

    mapping(bytes32 => Market) public markets;
    mapping(bytes32 => AssertedMarket) public assertedMarkets;
    bytes32[] public allMarketIds;

    FinderInterface public immutable finder;
    IERC20 public immutable currency;
    OptimisticOracleV3Interface public immutable oo;
    uint64 public constant assertionLiveness = 7200; // 2 hours
    bytes32 public immutable defaultIdentifier;
    bytes public constant unresolvable = "Unresolvable";

    uint256 public constant INITIAL_LIQUIDITY = 1e18; // 1 token of liquidity to start
    uint256 public constant FEE_PERCENTAGE = 3; // 0.3% fee

    event MarketInitialized(
        bytes32 indexed marketId,
        string outcome1,
        string outcome2,
        string description,
        address outcome1Token,
        address outcome2Token,
        uint256 reward,
        uint256 requiredBond
    );
    event MarketAsserted(
        bytes32 indexed marketId,
        string assertedOutcome,
        bytes32 indexed assertionId
    );
    event MarketResolved(bytes32 indexed marketId);
    event TokensCreated(
        bytes32 indexed marketId,
        address indexed account,
        uint256 tokensCreated
    );
    event TokensRedeemed(
        bytes32 indexed marketId,
        address indexed account,
        uint256 tokensRedeemed
    );
    event TokensSettled(
        bytes32 indexed marketId,
        address indexed account,
        uint256 payout,
        uint256 outcome1Tokens,
        uint256 outcome2Tokens
    );
    event OutcomeTokensPurchased(
        bytes32 indexed marketId,
        address indexed buyer,
        bool isOutcomeOne,
        uint256 tokensBought,
        uint256 currencySpent
    );

    constructor(
        address _finder,
        address _currency,
        address _optimisticOracleV3
    ) {
        finder = FinderInterface(_finder);
        require(
            _getCollateralWhitelist().isOnWhitelist(_currency),
            "Unsupported currency"
        );
        currency = IERC20(_currency);
        oo = OptimisticOracleV3Interface(_optimisticOracleV3);
        defaultIdentifier = oo.defaultIdentifier();
    }

    function getMarket(bytes32 marketId) public view returns (Market memory) {
        return markets[marketId];
    }

    function initializeMarket(
        string memory outcome1,
        string memory outcome2,
        string memory description,
        uint256 reward,
        uint256 requiredBond
    ) public returns (bytes32 marketId) {
        require(bytes(outcome1).length > 0, "Empty first outcome");
        require(bytes(outcome2).length > 0, "Empty second outcome");
        require(
            keccak256(bytes(outcome1)) != keccak256(bytes(outcome2)),
            "Outcomes are the same"
        );
        require(bytes(description).length > 0, "Empty description");
        marketId = keccak256(abi.encode(block.number, description));
        require(
            markets[marketId].outcome1Token == ExpandedIERC20(address(0)),
            "Market already exists"
        );

        ExpandedIERC20 outcome1Token = new ExpandedERC20(
            string(abi.encodePacked(outcome1, " Token")),
            "O1T",
            18
        );
        ExpandedIERC20 outcome2Token = new ExpandedERC20(
            string(abi.encodePacked(outcome2, " Token")),
            "O2T",
            18
        );
        outcome1Token.addMinter(address(this));
        outcome2Token.addMinter(address(this));
        outcome1Token.addBurner(address(this));
        outcome2Token.addBurner(address(this));

        markets[marketId] = Market({
            resolved: false,
            assertedOutcomeId: bytes32(0),
            outcome1Token: outcome1Token,
            outcome2Token: outcome2Token,
            reward: reward,
            requiredBond: requiredBond,
            outcome1: bytes(outcome1),
            outcome2: bytes(outcome2),
            description: bytes(description),
            outcome1Pool: INITIAL_LIQUIDITY,
            outcome2Pool: INITIAL_LIQUIDITY
        });

        outcome1Token.mint(address(this), INITIAL_LIQUIDITY);
        outcome2Token.mint(address(this), INITIAL_LIQUIDITY);

        if (reward > 0)
            currency.safeTransferFrom(msg.sender, address(this), reward);
        currency.safeTransferFrom(
            msg.sender,
            address(this),
            INITIAL_LIQUIDITY * 2
        );

        allMarketIds.push(marketId);

        emit MarketInitialized(
            marketId,
            outcome1,
            outcome2,
            description,
            address(outcome1Token),
            address(outcome2Token),
            reward,
            requiredBond
        );
    }

    function getAllMarkets()
        public
        view
        returns (bytes32[] memory, Market[] memory)
    {
        Market[] memory allMarkets = new Market[](allMarketIds.length);

        for (uint i = 0; i < allMarketIds.length; i++) {
            allMarkets[i] = markets[allMarketIds[i]];
        }

        return (allMarketIds, allMarkets);
    }

    function assertMarket(
        bytes32 marketId,
        string memory assertedOutcome
    ) public returns (bytes32 assertionId) {
        Market storage market = markets[marketId];
        require(
            market.outcome1Token != ExpandedIERC20(address(0)),
            "Market does not exist"
        );
        bytes32 assertedOutcomeId = keccak256(bytes(assertedOutcome));
        require(
            market.assertedOutcomeId == bytes32(0),
            "Assertion active or resolved"
        );
        require(
            assertedOutcomeId == keccak256(market.outcome1) ||
                assertedOutcomeId == keccak256(market.outcome2) ||
                assertedOutcomeId == keccak256(unresolvable),
            "Invalid asserted outcome"
        );

        market.assertedOutcomeId = assertedOutcomeId;
        uint256 minimumBond = oo.getMinimumBond(address(currency));
        uint256 bond = market.requiredBond > minimumBond
            ? market.requiredBond
            : minimumBond;
        bytes memory claim = _composeClaim(assertedOutcome, market.description);

        currency.safeTransferFrom(msg.sender, address(this), bond);
        currency.safeApprove(address(oo), bond);
        assertionId = _assertTruthWithDefaults(claim, bond);

        assertedMarkets[assertionId] = AssertedMarket({
            asserter: msg.sender,
            marketId: marketId
        });

        emit MarketAsserted(marketId, assertedOutcome, assertionId);
    }

    function assertionResolvedCallback(
        bytes32 assertionId,
        bool assertedTruthfully
    ) public {
        require(msg.sender == address(oo), "Not authorized");
        Market storage market = markets[assertedMarkets[assertionId].marketId];

        if (assertedTruthfully) {
            market.resolved = true;
            if (market.reward > 0)
                currency.safeTransfer(
                    assertedMarkets[assertionId].asserter,
                    market.reward
                );
            emit MarketResolved(assertedMarkets[assertionId].marketId);
        } else market.assertedOutcomeId = bytes32(0);
        delete assertedMarkets[assertionId];
    }

    function assertionDisputedCallback(bytes32 assertionId) public {}

    function createOutcomeTokens(
        bytes32 marketId,
        uint256 tokensToCreate
    ) public {
        Market storage market = markets[marketId];
        require(
            market.outcome1Token != ExpandedIERC20(address(0)),
            "Market does not exist"
        );

        currency.safeTransferFrom(msg.sender, address(this), tokensToCreate);

        market.outcome1Token.mint(msg.sender, tokensToCreate);
        market.outcome2Token.mint(msg.sender, tokensToCreate);

        market.outcome1Pool += tokensToCreate;
        market.outcome2Pool += tokensToCreate;

        emit TokensCreated(marketId, msg.sender, tokensToCreate);
    }

    function redeemOutcomeTokens(
        bytes32 marketId,
        uint256 tokensToRedeem
    ) public {
        Market storage market = markets[marketId];
        require(
            market.outcome1Token != ExpandedIERC20(address(0)),
            "Market does not exist"
        );

        market.outcome1Token.burnFrom(msg.sender, tokensToRedeem);
        market.outcome2Token.burnFrom(msg.sender, tokensToRedeem);

        currency.safeTransfer(msg.sender, tokensToRedeem);

        market.outcome1Pool -= tokensToRedeem;
        market.outcome2Pool -= tokensToRedeem;

        emit TokensRedeemed(marketId, msg.sender, tokensToRedeem);
    }

    function settleOutcomeTokens(
        bytes32 marketId
    ) public returns (uint256 payout) {
        Market storage market = markets[marketId];
        require(market.resolved, "Market not resolved");

        uint256 outcome1Balance = market.outcome1Token.balanceOf(msg.sender);
        uint256 outcome2Balance = market.outcome2Token.balanceOf(msg.sender);

        if (market.assertedOutcomeId == keccak256(market.outcome1))
            payout = outcome1Balance;
        else if (market.assertedOutcomeId == keccak256(market.outcome2))
            payout = outcome2Balance;
        else payout = (outcome1Balance + outcome2Balance) / 2;

        market.outcome1Token.burnFrom(msg.sender, outcome1Balance);
        market.outcome2Token.burnFrom(msg.sender, outcome2Balance);
        currency.safeTransfer(msg.sender, payout);

        emit TokensSettled(
            marketId,
            msg.sender,
            payout,
            outcome1Balance,
            outcome2Balance
        );
    }

    function buyOutcomeTokens(
        bytes32 marketId,
        bool isOutcomeOne,
        uint256 maxCurrencySpent
    ) public returns (uint256 tokensBought) {
        Market storage market = markets[marketId];
        require(
            market.outcome1Token != ExpandedIERC20(address(0)),
            "Market does not exist"
        );
        require(!market.resolved, "Market already resolved");

        uint256 currencyIn = maxCurrencySpent;
        uint256 tokenPool = isOutcomeOne
            ? market.outcome1Pool
            : market.outcome2Pool;
        uint256 otherPool = isOutcomeOne
            ? market.outcome2Pool
            : market.outcome1Pool;

        tokensBought = (currencyIn * tokenPool) / (otherPool + currencyIn);

        uint256 fee = (tokensBought * FEE_PERCENTAGE) / 1000;
        tokensBought -= fee;

        require(tokensBought > 0, "Insufficient output amount");

        currency.safeTransferFrom(msg.sender, address(this), currencyIn);

        if (isOutcomeOne) {
            market.outcome1Token.mint(msg.sender, tokensBought);
            market.outcome1Pool += currencyIn;
        } else {
            market.outcome2Token.mint(msg.sender, tokensBought);
            market.outcome2Pool += currencyIn;
        }

        emit OutcomeTokensPurchased(
            marketId,
            msg.sender,
            isOutcomeOne,
            tokensBought,
            currencyIn
        );
        return tokensBought;
    }

    function _getCollateralWhitelist()
        internal
        view
        returns (AddressWhitelist)
    {
        return
            AddressWhitelist(
                finder.getImplementationAddress(
                    OracleInterfaces.CollateralWhitelist
                )
            );
    }

    function _composeClaim(
        string memory outcome,
        bytes memory description
    ) internal view returns (bytes memory) {
        return
            abi.encodePacked(
                "As of assertion timestamp ",
                ClaimData.toUtf8BytesUint(block.timestamp),
                ", the described prediction market outcome is: ",
                outcome,
                ". The market description is: ",
                description
            );
    }

    function _assertTruthWithDefaults(
        bytes memory claim,
        uint256 bond
    ) internal returns (bytes32 assertionId) {
        assertionId = oo.assertTruth(
            claim,
            msg.sender,
            address(this),
            address(0),
            assertionLiveness,
            currency,
            bond,
            defaultIdentifier,
            bytes32(0)
        );
    }
}
