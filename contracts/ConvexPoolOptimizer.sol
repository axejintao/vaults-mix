// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {IERC20Upgradeable} from "@openzeppelin-contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {SafeMathUpgradeable} from "@openzeppelin-contracts-upgradeable/math/SafeMathUpgradeable.sol";
import {MathUpgradeable} from "@openzeppelin-contracts-upgradeable/math/MathUpgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin-contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import {BaseStrategy} from "@badger-finance/BaseStrategy.sol";

import {CurveSwapper} from "deps/CurveSwapper.sol";
import {UniswapSwapper} from "deps/UniswapSwapper.sol";
import {TokenSwapPathRegistry} from "deps/TokenSwapPathRegistry.sol";
import {ConvexVaultDepositor} from "./ConvexVaultDepositor.sol";

import "interfaces/convex/IBooster.sol";
import "interfaces/convex/ICrvDepositor.sol";
import "interfaces/convex/IBaseRewardsPool.sol";
import "interfaces/badger/IVault.sol";
import "interfaces/curve/ICurveFi.sol";

contract ConvexPoolOptimizer is BaseStrategy, CurveSwapper, UniswapSwapper, TokenSwapPathRegistry, ConvexVaultDepositor {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeMathUpgradeable for uint256;

    // Curve + Convex Adresses
    address private constant convexBooster = 0xF403C135812408BFbE8713b5A23a04b3D48AAE31;

    // Badger Infrastructure Addresses
    address private constant badgerTreeAddress = 0x660802Fc641b154aBA66a62137e71f331B6d787A;

    // Curve + Convex Contracts
    IBooster private constant booster = IBooster(convexBooster);

    // Strategy Specific Information
    uint256 public pid;
    uint256 public stableSwapSlippageTolerance;
    IBaseRewardsPool public baseRewardsPool;

    /**
     * @param _vault Strategy vault implementation
     * @param _wantConfig [want] Configuration array
     */
    function initialize(
        address _vault,
        address[1] memory _wantConfig,
        uint256 _pid,
        uint256 _stableSwapSlippageTolerance,
        uint256 _autoCompoundRatio
    ) public initializer {
        __BaseStrategy_init(_vault);

        want = _wantConfig[0];
        pid = _pid;
        stableSwapSlippageTolerance = _stableSwapSlippageTolerance;
        autoCompoundRatio = _autoCompoundRatio;

        /// @dev verify the configuration is in fact valid
        IBooster.PoolInfo memory poolInfo = booster.poolInfo(pid);
        require(poolInfo.lptoken == want, "INVALID_WANT_CONFIG");
        baseRewardsPool = IBaseRewardsPool(poolInfo.crvRewards);
        require(poolInfo.token == baseRewardsPool.stakingToken(), "INVALID_POOL_CONFIG");

        // Setup Token Approvals
        IERC20Upgradeable(want).safeApprove(convexBooster, type(uint256).max);
        _setupApprovals();
    }

    /// @dev Return the name of the strategy
    function getName() external pure override returns (string memory) {
        return "ConvexOptimizer";
    }

    /// @dev Return a list of protected tokens
    /// @notice It's very important all tokens that are meant to be in the strategy to be marked as protected
    /// @notice this provides security guarantees to the depositors they can't be sweeped away
    function getProtectedTokens() public view virtual override returns (address[] memory) {
        address[] memory protectedTokens = new address[](6);
        protectedTokens[0] = want;
        protectedTokens[1] = CRV_ADDRESS;
        protectedTokens[2] = CVX_ADDRESS;
        protectedTokens[3] = CVXCRV_ADDRESS;
        protectedTokens[4] = BVECVX_ADDRESS;
        protectedTokens[5] = BCVXCRV_ADDRESS;
        return protectedTokens;
    }

    /// @dev Deposit `_amount` of want, investing it to earn yield
    function _deposit(uint256 _amount) internal override {
        booster.deposit(pid, _amount, true);
    }

    /// @dev Withdraw all funds, this is used for migrations, most of the time for emergency reasons
    function _withdrawAll() internal override {
        baseRewardsPool.withdrawAndUnwrap(balanceOfPool(), false);
    }

    /// @dev Withdraw `_amount` of want, so that it can be sent to the vault / depositor
    /// @notice just unlock the funds and return the amount you could unlock
    function _withdrawSome(uint256 _amount) internal override returns (uint256) {
        // Get idle want in the strategy
        uint256 _preWant = IERC20Upgradeable(want).balanceOf(address(this));

        // If we lack sufficient idle want, withdraw the difference from the strategy position
        if (_preWant < _amount) {
            uint256 _toWithdraw = _amount.sub(_preWant);
            baseRewardsPool.withdrawAndUnwrap(_toWithdraw, false);
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
        uint256 currentWant = balanceOfWant();
        uint256 baseRewardsCount = 2 + autoCompoundRatio > 0 ? 1 : 0;
        uint256 extraRewardsCount = baseRewardsPool.extraRewardsLength();
        harvested = new TokenAmount[](baseRewardsCount + extraRewardsCount);
        harvested[0].token = BCVXCRV_ADDRESS;
        harvested[1].token = BVECVX_ADDRESS;
        harvested[2].token = want;

        // Claim vault CRV rewards + extra incentives
        baseRewardsPool.getReward(address(this), true);

        // Calculate how much CRV to compound and distribute
        uint256 crvBalance = CRV.balanceOf(address(this));
        uint256 crvCompounded = crvBalance.mul(autoCompoundRatio).div(MAX_BPS);
        uint256 crvDistributed = crvBalance - crvCompounded;

        // Maximize our CVXCRV acquired and deposit into BCVXCRV
        if (crvDistributed > 0) {
            /*
             * It is possible to get a better rate for CRV:CVXCRV from the pool,
             * we will check the pool swap to verify this case - if the rate is not
             * favorable then just use the standard deposit instead.
             *
             * Token 0: CRV
             * Token 1: CVXCRV
             * Usage: get_dy(token0, token1, amount);
             *
             * Pool Index: 2
             * Usage: _exchange(in, out, amount, minOut, poolIndex, isFactory);
             */
            uint256 cvxCrvReceived = CRV_CVXCRV_POOL.get_dy(0, 1, crvDistributed);
            uint256 swapThreshold = crvDistributed.mul(MAX_BPS.add(stableSwapSlippageTolerance)).div(MAX_BPS);
            if (cvxCrvReceived > swapThreshold) {
                uint256 cvxCrvMinOut = crvDistributed.mul(MAX_BPS.sub(stableSwapSlippageTolerance)).div(MAX_BPS);
                _exchange(CRV_ADDRESS, CVXCRV_ADDRESS, crvDistributed, cvxCrvMinOut, 2, true);
            } else {
                // Deposit, but do not stake the CRV to get CVXCRV
                CRV_DEPOSITOR.deposit(crvDistributed, false);
            }

            /*
             * Deposit acquired CVXCRV into the vault and report.
             * Due to the block lock, we will deposit on behalf of the Badger Tree
             */
            BCVXCRV.deposit(CVXCRV.balanceOf(address(this)));
            uint256 bcvxCrvBalance = BCVXCRV.balanceOf(address(this));
            harvested[0].amount = bcvxCrvBalance;
            _processExtraToken(BCVXCRV_ADDRESS, bcvxCrvBalance);
        }

        // Calculate how much CVX to compound and distribute
        uint256 cvxBalance = CVX.balanceOf(address(this));
        uint256 cvxCompounded = cvxBalance.mul(autoCompoundRatio).div(MAX_BPS);
        uint256 cvxDistributed = cvxBalance - cvxCompounded;

        if (cvxDistributed > 0) {
            /*
             * It is possible to get a better rate for CVX:BVECVX from the pool,
             * we will check the pool swap to verify this case - if the rate is not
             * favorable then just use the standard deposit instead.
             *
             * Token 0: CRV
             * Token 1: CVXCRV
             * Usage: get_dy(token0, token1, amount);
             *
             * Pool Index: 2
             * Usage: _exchange(in, out, amount, minOut, poolIndex, isFactory);
             */
            uint256 cvxCrvReceived = CRV_CVXCRV_POOL.get_dy(0, 1, crvDistributed);
            uint256 swapThreshold = crvDistributed.mul(MAX_BPS.add(stableSwapSlippageTolerance)).div(MAX_BPS);
            if (cvxCrvReceived > swapThreshold) {
                uint256 cvxCrvMinOut = crvDistributed.mul(MAX_BPS.sub(stableSwapSlippageTolerance)).div(MAX_BPS);
                _exchange(CRV_ADDRESS, CVXCRV_ADDRESS, crvDistributed, cvxCrvMinOut, 2, true);
            } else {
                // Deposit, but do not stake the CRV to get CVXCRV
                CRV_DEPOSITOR.deposit(crvDistributed, false);
            }

            /*
             * Deposit acquired CVX into the vault and report.
             * Due to the block lock, we will deposit on behalf of the Badger Tree
             */
            BVECVX.deposit(cvxDistributed);
            uint256 bveCvxBalance = BVECVX.balanceOf(address(this));
            harvested[1].amount = bveCvxBalance;
            _processExtraToken(BVECVX_ADDRESS, bveCvxBalance);
        }

        // TODO: Handle the extra rewards
        // This is probably an opinionated area, emit as a placeholder
        for (uint256 i = 0; i < extraRewardsCount; i++) {
            address extraRewardsPoolAddress = baseRewardsPool.extraRewards(i);
            IBaseRewardsPool extraRewardsPool = IBaseRewardsPool(extraRewardsPoolAddress);
            address rewardToken = extraRewardsPool.rewardToken();
            // Handle an edge case where a pool has CVX or CRV bonus rewards
            if (rewardToken == CVX_ADDRESS || rewardToken == CRV_ADDRESS) {
                continue;
            }
            uint256 rewardTokenBalance = IERC20Upgradeable(rewardToken).balanceOf(address(this));
            if (rewardTokenBalance > 0) {
                harvested[i + 3].amount = rewardTokenBalance;
                _processExtraToken(rewardToken, rewardTokenBalance);
            }
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
            rewards[i + 3] = TokenAmount(extraRewardsPool.rewardToken(), extraRewardsPool.rewards(address(this)));
        }
        return rewards;
    }
}
