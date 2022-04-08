// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {SafeERC20Upgradeable} from "@openzeppelin-contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin-contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {MathUpgradeable} from "@openzeppelin-contracts-upgradeable/math/MathUpgradeable.sol";

import {CurveSwapper} from "deps/CurveSwapper.sol";

import {ICurveFi} from "interfaces/curve/ICurveFi.sol";
import {ICrvDepositor} from "interfaces/convex/ICrvDepositor.sol";
import {IVault} from "interfaces/badger/IVault.sol";

/**
 * @dev Contract for facilitating optimal Convex + Curve operations as well as convenience methods.
 */
contract ConvexVaultDepositor is CurveSwapper {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // Math Constants (duplicate from TheVault)
    uint256 private constant MAX_BPS = 10_000;

    // Pool Addresses
    address internal constant CVXCRV_CRV_POOL_ADDRESS = 0x9D0464996170c6B9e75eED71c68B99dDEDf279e8;
    address internal constant CVX_BVECVX_POOL_ADDRESS = 0x04c90C198b2eFF55716079bc06d7CCc4aa4d7512;

    // Token Addresses
    address internal constant CRV_ADDRESS = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address internal constant CVX_ADDRESS = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;
    address internal constant CVXCRV_ADDRESS = 0x62B9c7356A2Dc64a1969e19C23e4f579F9810Aa7;

    // Infrastructure Addresses
    address internal constant CRV_DEPOSITOR_ADDRESS = 0x8014595F2AB54cD7c604B00E9fb932176fDc86Ae;
    address internal constant BVECVX_ADDRESS = 0xfd05D3C7fe2924020620A8bE4961bBaA747e6305;
    address internal constant BCVXCRV_ADDRESS = 0x2B5455aac8d64C14786c3a29858E43b5945819C0;

    // Pools
    ICurveFi public constant CRV_CVXCRV_POOL = ICurveFi(CVXCRV_CRV_POOL_ADDRESS);
    ICurveFi public constant CVX_BVECVX_POOL = ICurveFi(CVX_BVECVX_POOL_ADDRESS);

    // Tokens
    IERC20Upgradeable public constant CRV = IERC20Upgradeable(CRV_ADDRESS);
    IERC20Upgradeable public constant CVX = IERC20Upgradeable(CVX_ADDRESS);
    IERC20Upgradeable public constant CVXCRV = IERC20Upgradeable(CVXCRV_ADDRESS);

    // Convex Contracts
    ICrvDepositor public constant CRV_DEPOSITOR = ICrvDepositor(CRV_DEPOSITOR_ADDRESS);

    // Badger Vaults
    IVault public constant BCVXCRV = IVault(BCVXCRV_ADDRESS);
    IVault public constant BVECVX = IVault(BVECVX_ADDRESS);

    /**
     * @dev Allow token swaps across curve pools for staking assets.
     */
    function _setupApprovals() internal {
      CRV.safeApprove(CRV_DEPOSITOR_ADDRESS, type(uint256).max);
      CRV.safeApprove(CVXCRV_CRV_POOL_ADDRESS, type(uint256).max);
      CVXCRV.safeApprove(BCVXCRV_ADDRESS, type(uint256).max);
      CVX.safeApprove(CVX_BVECVX_POOL_ADDRESS, type(uint256).max);
      CVX.safeApprove(BVECVX_ADDRESS, type(uint256).max);
    }

    /**
      * @notice It is possible to get a better rate for CRV:CVXCRV from the pool,
      * we will check the pool swap to verify this case - if the rate is not
      * favorable then just use the standard deposit instead.
      *
      * Token 0: CRV
      * Token 1: CVXCRV
      * Usage: get_dy(token0, token1, amount);
      *
      * Pool Index: 2
      * Usage: _exchange(in, out, amount, minOut, poolIndex, isFactory);
      * 0x9D0464996170c6B9e75eED71c68B99dDEDf279e8
      *
      * @param _amount CRV conversion amount
      * @param _slippage slippage in BPS
      * @return converted amount of CVXCRV received
      */
    function _convertCrv(uint256 _amount, uint256 _slippage) internal returns (uint256 converted) {
      uint256 cvxCrvBalanceBefore = CVXCRV.balanceOf(address(this));

      uint256 cvxCrvReceived = CRV_CVXCRV_POOL.get_dy(0, 1, _amount);
      uint256 swapThreshold = _amount.mul(MAX_BPS.add(_slippage)).div(MAX_BPS);
      uint256 cvxCrvMinOut = _amount.mul(MAX_BPS.sub(_slippage)).div(MAX_BPS);
      if (cvxCrvReceived > swapThreshold) {
          _exchange(CRV_ADDRESS, CVXCRV_ADDRESS, _amount, cvxCrvMinOut, 2, true);
      } else {
          // Deposit, but do not stake the CRV to get CVXCRV
          CRV_DEPOSITOR.deposit(_amount, false);
      }

      uint256 cvxCrvBalanceAfter = CVXCRV.balanceOf(address(this));
      uint256 cvxCrvGained = cvxCrvBalanceAfter - cvxCrvBalanceBefore;
      // Ensure our choice actually resulted in an optimized action
      require(cvxCrvGained > MathUpgradeable.max(cvxCrvMinOut, _amount), "INVALID_CRV_CONVERSION");

      return cvxCrvGained;
    }

    /**
      * @notice It is possible to get a better rate for CVX:BVECVX from the pool,
      * we will check the pool swap to verify this case - if the rate is not
      * favorable then just use the standard deposit instead.
      *
      * Token 0: CVX
      * Token 1: BVECVX
      * Usage: get_dy(token0, token1, amount);
      *
      * Pool Index: 0
      * Usage: _exchange(in, out, amount, minOut, poolIndex, isFactory);
      * 0x04c90C198b2eFF55716079bc06d7CCc4aa4d7512
      *
      * @param _amount CRV conversion amount
      * @param _slippage slippage in BPS
      * @return converted amount of CVXCRV received
      */
    function _convertCvx(uint256 _amount, uint256 _slippage) internal returns (uint256 converted) {
      uint256 bveCvxBalanceBefore = BVECVX.balanceOf(address(this));

      // temporarily only swap in to BVECVX
      uint256 bveCvxMinOut = _amount.mul(MAX_BPS.sub(_slippage)).div(MAX_BPS);
      _exchange(CVX_ADDRESS, BVECVX_ADDRESS, _amount, bveCvxMinOut, 0, true);

      // TODO: enable this snippet, removing the above once BVECVX vault is v1.5
      // uint256 cvxReceived = CVX_BVECVX_POOL.get_dy(0, 1, _amount);
      // uint256 swapThreshold = _amount.mul(MAX_BPS.add(_slippage)).div(MAX_BPS);
      // if (cvxReceived > swapThreshold) {
      //     uint256 bveCvxMinOut = _amount.mul(MAX_BPS.sub(_slippage)).div(MAX_BPS);
      //     _exchange(CVX_ADDRESS, BVECVX_ADDRESS, _amount, bveCvxMinOut, 0, true);
      // } else {
      //     BVECVX.deposit(cvxReceived);
      // }

      uint256 bveCvxBalanceAfter = BVECVX.balanceOf(address(this));
      uint256 bveCvxGained = bveCvxBalanceAfter - bveCvxBalanceBefore;
      // Ensure our choice actually resulted in an optimized action
      require(bveCvxGained > MathUpgradeable.max(bveCvxMinOut, _amount), "INVALID_CVX_CONVERSION");

      return bveCvxGained;
    }

    /// @dev Adapted from https://docs.convexfinance.com/convexfinanceintegration/CVX-minting
    /// @notice Only used for view functions to estimate APR
    function getCvxMint(uint256 _earned) internal view returns (uint256) {
        uint256 cvxTotalSupply = CVX.totalSupply();
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
