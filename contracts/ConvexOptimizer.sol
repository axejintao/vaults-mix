// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {IERC20Upgradeable} from "@openzeppelin-contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {SafeMathUpgradeable} from "@openzeppelin-contracts-upgradeable/math/SafeMathUpgradeable.sol";
import {MathUpgradeable} from "@openzeppelin-contracts-upgradeable/math/MathUpgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin-contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import {BaseStrategy} from "@badger-finance/BaseStrategy.sol";

import "interfaces/convex/IBooster.sol";
import "interfaces/convex/ICrvDepositor.sol";
import "interfaces/convex/IBaseRewardsPool.sol";
import "interfaces/badger/IVault.sol";

contract ConvexOptimizer is BaseStrategy {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeMathUpgradeable for uint256;

    // Curve + Convex Adresses
    address private constant curveAdressProvider = 0x0000000022D53366457F9d5E68Ec105046FC4383;
    address private constant convexBooster = 0xF403C135812408BFbE8713b5A23a04b3D48AAE31;
    address private constant convexCrvDepositor = 0x8014595F2AB54cD7c604B00E9fb932176fDc86Ae;

    // Token Addresses
    address private constant crvAddress = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address private constant cvxAddress = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;
    address private constant cvxCrvAddress = 0x62B9c7356A2Dc64a1969e19C23e4f579F9810Aa7;
    address private constant bveCvxAddress = 0xfd05D3C7fe2924020620A8bE4961bBaA747e6305;
    address private constant bcvxCrvAddress = 0x2B5455aac8d64C14786c3a29858E43b5945819C0;

    // Tokens
    IERC20Upgradeable private constant crv = IERC20Upgradeable(crvAddress);
    IERC20Upgradeable private constant cvx = IERC20Upgradeable(cvxAddress);
    IERC20Upgradeable private constant cvxCrv = IERC20Upgradeable(cvxCrvAddress);

    // Badger Vaults
    IVault private constant bveCvx = IVault(bveCvxAddress);
    IVault private constant bcvxCrv = IVault(bcvxCrvAddress);

    // Convex Contracts
    IBooster private constant booster = IBooster(convexBooster);
    ICrvDepositor private constant crvDepositor = ICrvDepositor(convexCrvDepositor);

    // Strategy Specific Information
    uint256 public pid;
    IBaseRewardsPool public baseRewardsPool;

    /**
     * @param _vault Strategy vault implementation
     * @param _wantConfig [want] Configuration array
     */
    function initialize(
        address _vault,
        address[1] memory _wantConfig,
        uint256 _pid,
        uint256 _autoCompoundRatio
    ) public initializer {
        __BaseStrategy_init(_vault);

        want = _wantConfig[0];
        pid = _pid;
        autoCompoundRatio = _autoCompoundRatio;

        IBooster.PoolInfo memory poolInfo = booster.poolInfo(pid);
        baseRewardsPool = IBaseRewardsPool(poolInfo.crvRewards);
        /// @dev verify the configuration is in fact valid
        require(baseRewardsPool.stakingToken() == want, "INVALID");

        // Setup Token Approvals
        IERC20Upgradeable(want).safeApprove(address(booster), type(uint256).max);
        crv.safeApprove(address(crvDepositor), type(uint256).max);
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
        protectedTokens[1] = crvAddress;
        protectedTokens[2] = cvxAddress;
        protectedTokens[3] = cvxCrvAddress;
        protectedTokens[4] = bveCvxAddress;
        protectedTokens[5] = bcvxCrvAddress;
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
        address[] memory extraRewards = baseRewardsPool.extraRewards();
        uint256 baseRewardsCount = 2 + autoCompoundRatio > 0 ? 1 : 0;
        harvested = new TokenAmount[](extraRewards.length + baseRewardsCount);
        harvested[0].token = bcvxCrvAddress;
        harvested[1].token = bveCvxAddress;
        harvested[2].token = want;

        // Claim vault CRV rewards + extra incentives
        baseRewardsPool.getReward(address(this), true);

        // Calculate how much CRV to compound and distribute
        uint256 crvBalance = crv.balanceOf(address(this));
        uint256 crvCompounded = crvBalance.mul(autoCompoundRatio).div(MAX_BPS);
        uint256 crvDistributed = crvBalance - crvCompounded;

        // Maximize our cvxCRV acquired and deposit into bcvxCRV
        if (crvDistributed > 0) {
            /**
            * It is possible to get a better rate for CRV:cvxCRV from the pool,
            * we will check the pool swap to verify this case - if the rate is not
            * favorable then just use the standard deposit instead.
            */
            // if () {
            //     // TODO: Check current crv -> cvxCRV pool swap rate
            // } else {
            //     crvDepositor.deposit(currentCrv, false);
            // }

            // TODO: simple deposit for now
            crvDepositor.deposit(crvDistributed, false);

            // Deposit acquired cvxCRV into the vault and report
            bcvxCrv.deposit(cvxCrv.balanceOf(address(this)));
            uint256 bcvxCrvBalance = bcvxCrv.balanceOf(address(this));
            harvested[0].amount = bcvxCrvBalance;
            _processExtraToken(bcvxCrvAddress, bcvxCrvBalance);
        }

        // Calculate how much CVX to compound and distribute
        uint256 cvxBalance = cvx.balanceOf(address(this));
        uint256 cvxCompounded = cvxBalance.mul(autoCompoundRatio).div(MAX_BPS);
        uint256 cvxDistributed = cvxBalance - cvxCompounded;

        if (cvxDistributed > 0) {
            bveCvx.deposit(cvxDistributed);
            uint256 bveCvxBalance = bveCvx.balanceOf(address(this));
            harvested[1].amount = bveCvxBalance;
            _processExtraToken(bveCvxAddress, bveCvxBalance);
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
        address[] memory extraRewards = baseRewardsPool.extraRewards();
        rewards = new TokenAmount[](extraRewards.length + 2);
        uint256 crvRewards = baseRewardsPool.rewards(address(this));
        rewards[0] = TokenAmount(crvAddress, crvRewards);
        rewards[1] = TokenAmount(cvxAddress, getCvxMint(crvRewards));
        for (uint256 i = 0; i < extraRewards.length; i++) {
            IBaseRewardsPool extraRewardsPool = IBaseRewardsPool(extraRewards[i]);
            rewards[i + 2] = TokenAmount(extraRewards[i], extraRewardsPool.rewards(address(this)));
        }
        return rewards;
    }

    /// @dev Adapted from https://docs.convexfinance.com/convexfinanceintegration/cvx-minting
    function getCvxMint(uint256 _earned) internal view returns (uint256) {
        uint256 cvxTotalSupply = cvx.totalSupply();
        uint256 currentCliff = cvxTotalSupply / 100000e18;
        if (currentCliff < 1000) {
            uint256 remaining = 1000 - currentCliff;
            uint256 cvxEarned = (_earned * remaining) / 1000;
            uint256 amountTillMax = 100000000e18 - cvxTotalSupply;
            if (cvxEarned > amountTillMax) {
                cvxEarned = amountTillMax;
            }
            return cvxEarned;
        }
        return 0;
    }
}
