// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {IERC20Upgradeable} from "@openzeppelin-contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {SafeMathUpgradeable} from "@openzeppelin-contracts-upgradeable/math/SafeMathUpgradeable.sol";
import {MathUpgradeable} from "@openzeppelin-contracts-upgradeable/math/MathUpgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin-contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import {BaseStrategy} from "@badger-finance/BaseStrategy.sol";

import {UniswapSwapper} from "deps/UniswapSwapper.sol";
import {TokenSwapPathRegistry} from "deps/TokenSwapPathRegistry.sol";
import {ConvexVaultDepositor} from "./ConvexVaultDepositor.sol";

import {IBaseRewardsPool} from "interfaces/convex/IBaseRewardsPool.sol";

contract ConvexCrvOptimizer is BaseStrategy, UniswapSwapper, ConvexVaultDepositor, TokenSwapPathRegistry {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeMathUpgradeable for uint256;

    // Token Addresses
    address private constant THREE_CRV_ADDRESS = 0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490;
    address private constant USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Infrastructure Addresses
    address private constant CVXCRV_REWARDS_ADDRESS = 0x3Fe65692bfCD0e6CF84cB1E7d24108E434A7587e;
    address private constant THREE_POOL_ADDRESS = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;

    // Tokens
    IERC20Upgradeable public constant THREE_CRV = IERC20Upgradeable(THREE_CRV_ADDRESS);
    IERC20Upgradeable public constant USDC = IERC20Upgradeable(USDC_ADDRESS);

    // Strategy Specific Information
    IBaseRewardsPool public baseRewardsPool = IBaseRewardsPool(CVXCRV_REWARDS_ADDRESS);
    uint256 public sl;

    /**
     * @param _vault Strategy vault implementation
     * @param _wantConfig [want] Configuration array
     */
    function initialize(
        address _vault,
        address[1] memory _wantConfig,
        uint256 _sl
    ) public initializer {
        __BaseStrategy_init(_vault);

        want = _wantConfig[0];
        sl = _sl;

        address[] memory path = new address[](3);
        path[0] = USDC_ADDRESS;
        path[1] = WETH_ADDRESS;
        path[2] = CRV_ADDRESS;
        _setTokenSwapPath(USDC_ADDRESS, CRV_ADDRESS, path);

        _setupApprovals();
        CVXCRV.safeApprove(CVXCRV_REWARDS_ADDRESS, type(uint256).max);
    }

    /// @dev Set stable swap slippage tolerance
    function setSlippage(uint256 _sl) external whenNotPaused {
        _onlyAuthorizedActors();
        require(_sl <= MAX_BPS, "INVALID_SL");
        sl = _sl;
    }

    /// @dev Return the name of the strategy
    function getName() external pure override returns (string memory) {
        return "ConvexCrvOptimizer";
    }

    /// @dev Return a list of protected tokens
    /// @notice It's very important all tokens that are meant to be in the strategy to be marked as protected
    /// @notice this provides security guarantees to the depositors they can't be sweeped away
    function getProtectedTokens() public view virtual override returns (address[] memory) {
        address[] memory protectedTokens = new address[](7);
        protectedTokens[0] = want; // CVXCRV
        protectedTokens[1] = CRV_ADDRESS;
        protectedTokens[2] = CVX_ADDRESS;
        protectedTokens[3] = THREE_CRV_ADDRESS;
        protectedTokens[4] = BVECVX_ADDRESS;
        protectedTokens[5] = BCVXCRV_ADDRESS;
        protectedTokens[6] = USDC_ADDRESS;
        return protectedTokens;
    }

    /// @dev Deposit `_amount` of want, investing it to earn yield
    function _deposit(uint256 _amount) internal override {
        baseRewardsPool.stake(_amount);
    }

    /// @dev Withdraw all funds, this is used for migrations, most of the time for emergency reasons
    function _withdrawAll() internal override {
        if (balanceOfPool() > 0) {
            baseRewardsPool.withdrawAll(false);
        }
    }

    /// @dev Withdraw `_amount` of want, so that it can be sent to the vault / depositor
    /// @notice just unlock the funds and return the amount you could unlock
    function _withdrawSome(uint256 _amount) internal override returns (uint256) {
        // Get idle want in the strategy
        uint256 _preWant = IERC20Upgradeable(want).balanceOf(address(this));

        // If we lack sufficient idle want, withdraw the difference from the strategy position
        if (_preWant < _amount) {
            uint256 _toWithdraw = _amount.sub(_preWant);
            baseRewardsPool.withdraw(_toWithdraw, false);
        }

        // Confirm how much want we actually end up with
        uint256 _postWant = IERC20Upgradeable(want).balanceOf(address(this));

        // Return the actual amount withdrawn if less than requested
        return MathUpgradeable.min(_postWant, _amount);
    }

    /// @dev No tend
    function _isTendable() internal pure override returns (bool) {
        return false;
    }

    function _harvest() internal override returns (TokenAmount[] memory harvested) {
        uint256 extraRewardsCount = baseRewardsPool.extraRewardsLength();
        harvested = new TokenAmount[](2);
        harvested[0].token = want;
        harvested[1].token = BVECVX_ADDRESS;

        // Claim vault CRV rewards + extra incentives
        baseRewardsPool.getReward(address(this), true);

        uint256 threeCrvEarned = THREE_CRV.balanceOf(address(this));

        if (threeCrvEarned > 0) {
            // Virtual Price of 3crv >= 1, ask for at least 1:1 back before slippage, convert to usdc decimals
            uint256 usdcMinOut = threeCrvEarned.mul(MAX_BPS.sub(sl)).div(MAX_BPS.mul(1e12));
            _remove_liquidity_one_coin(THREE_POOL_ADDRESS, threeCrvEarned, 1, usdcMinOut);
            uint256 usdcBalance = USDC.balanceOf(address(this));
            require(usdcBalance >= usdcMinOut, "INVALID_3CRV_CONVERT");
            _swapExactTokensForTokens(
                sushiswap,
                USDC_ADDRESS,
                usdcBalance,
                getTokenSwapPath(USDC_ADDRESS, CRV_ADDRESS)
            );
        }

        // Calculate how much CRV to compound and distribute
        uint256 crvEarned = CRV.balanceOf(address(this));

        // Maximize our CVXCRV acquired and deposit into BCVXCRV
        if (crvEarned > 0) {
            uint256 cvxCrvHarvested = _convertCrv(crvEarned, sl);
            _reportToVault(cvxCrvHarvested);
            _deposit(cvxCrvHarvested);
            harvested[0].amount = cvxCrvHarvested;
        }

        // Calculate how much CVX to compound and distribute
        uint256 cvxEarned = CVX.balanceOf(address(this));

        if (cvxEarned > 0) {
            uint256 bveCvxBalance = BVECVX.balanceOf(address(this));
            uint256 bveCvxGained = _convertCvx(cvxEarned, sl);
            uint256 cvxHarvested = bveCvxBalance + bveCvxGained;
            harvested[1].amount = cvxHarvested;
            _processExtraToken(BVECVX_ADDRESS, cvxHarvested);
        }
    }

    /// @dev No tend
    function _tend() internal override returns (TokenAmount[] memory tended) {
        return new TokenAmount[](0);
    }

    /// @dev Return the balance (in want) that the strategy has invested somewhere
    function balanceOfPool() public view override returns (uint256) {
        return baseRewardsPool.balanceOf(address(this));
    }

    /// @dev Return the balance of rewards that the strategy has accrued
    /// @notice Used for offChain APY and Harvest Health monitoring
    function balanceOfRewards() external view override returns (TokenAmount[] memory rewards) {
        uint256 extraRewards = baseRewardsPool.extraRewardsLength();
        rewards = new TokenAmount[](extraRewards + 2);
        uint256 crvRewards = baseRewardsPool.rewards(address(this));
        rewards[0] = TokenAmount(CRV_ADDRESS, crvRewards);
        rewards[1] = TokenAmount(CVX_ADDRESS, getCvxMint(crvRewards));
        for (uint256 i = 0; i < extraRewards; i++) {
            address extraRewardsPoolAddress = baseRewardsPool.extraRewards(i);
            IBaseRewardsPool extraRewardsPool = IBaseRewardsPool(extraRewardsPoolAddress);
            rewards[i + 2] = TokenAmount(extraRewardsPool.rewardToken(), extraRewardsPool.rewards(address(this)));
        }
        return rewards;
    }
}
