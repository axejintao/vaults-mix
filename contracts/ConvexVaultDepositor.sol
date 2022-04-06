// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {SafeERC20Upgradeable} from "@openzeppelin-contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin-contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

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
    address internal constant cvxCrvCrvPoolAddress = 0x9D0464996170c6B9e75eED71c68B99dDEDf279e8;
    address internal constant cvxBvecvxPoolAddress = 0x04c90C198b2eFF55716079bc06d7CCc4aa4d7512;

    // Token Addresses
    address internal constant crvAddress = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address internal constant cvxAddress = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;
    address internal constant cvxCrvAddress = 0x62B9c7356A2Dc64a1969e19C23e4f579F9810Aa7;

    // Infrastructure Addresses
    address internal constant crvDepositorAddress = 0x8014595F2AB54cD7c604B00E9fb932176fDc86Ae;
    address internal constant bveCvxAddress = 0xfd05D3C7fe2924020620A8bE4961bBaA747e6305;
    address internal constant bcvxCrvAddress = 0x2B5455aac8d64C14786c3a29858E43b5945819C0;

    // Pools
    ICurveFi internal constant cvxCrvCrvPool = ICurveFi(cvxCrvCrvPoolAddress);
    ICurveFi internal constant cvxBvecvxPool = ICurveFi(cvxBvecvxPoolAddress);

    // Tokens
    IERC20Upgradeable internal constant crv = IERC20Upgradeable(crvAddress);
    IERC20Upgradeable internal constant cvx = IERC20Upgradeable(cvxAddress);
    IERC20Upgradeable internal constant cvxCrv = IERC20Upgradeable(cvxCrvAddress);

    // Convex Contracts
    ICrvDepositor internal constant crvDepositor = ICrvDepositor(crvDepositorAddress);

    // Badger Vaults
    IVault internal constant bcvxCrv = IVault(bcvxCrvAddress);
    IVault internal constant bveCvx = IVault(bveCvxAddress);

    /**
     * @dev Allow token swaps across curve pools for staking assets.
     */
    function _setupApprovals() internal {
      crv.safeApprove(crvDepositorAddress, type(uint256).max);
      crv.safeApprove(cvxCrvCrvPoolAddress, type(uint256).max);
      cvx.safeApprove(cvxBvecvxPoolAddress, type(uint256).max);
      cvxCrv.safeApprove(bcvxCrvAddress, type(uint256).max);
      cvx.safeApprove(bveCvxAddress, type(uint256).max);
    }

    function _convertCrv(uint256 _amount, uint256 _slippage) internal {
      /*
        * It is possible to get a better rate for CRV:cvxCRV from the pool,
        * we will check the pool swap to verify this case - if the rate is not
        * favorable then just use the standard deposit instead.
        *
        * Token 0: CRV
        * Token 1: cvxCRV
        * Usage: get_dy(token0, token1, amount);
        *
        * Pool Index: 2
        * Usage: _exchange(in, out, amount, minOut, poolIndex, isFactory);
        */
      uint256 cvxCrvReceived = cvxCrvCrvPool.get_dy(0, 1, _amount);
      uint256 swapThreshold = _amount.mul(MAX_BPS.add(_slippage)).div(MAX_BPS);
      if (cvxCrvReceived > swapThreshold) {
          uint256 cvxCrvMinOut = _amount.mul(MAX_BPS.sub(_slippage)).div(MAX_BPS);
          _exchange(crvAddress, cvxCrvAddress, _amount, cvxCrvMinOut, 2, true);
      } else {
          // Deposit, but do not stake the CRV to get cvxCRV
          crvDepositor.deposit(_amount, false);
      }
    }
}
