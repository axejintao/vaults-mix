import time

from brownie import (
    ConvexCrvOptimizer,
    TheVault,
    interface,
    accounts,
)
from brownie import interface;
from _setup.config import (
    WANT, 
    WHALE_ADDRESS,

    PERFORMANCE_FEE_GOVERNANCE,
    PERFORMANCE_FEE_STRATEGIST,
    WITHDRAWAL_FEE,
    MANAGEMENT_FEE,
)
from helpers.constants import MaxUint256
from helpers.time import days
from rich.console import Console

console = Console()

from dotmap import DotMap
import pytest


## Accounts ##
@pytest.fixture
def deployer():
    return accounts[0]

@pytest.fixture
def user():
    return accounts[9]


## Fund the account
@pytest.fixture
def want(deployer):
    TOKEN_ADDRESS = WANT
    token = interface.IERC20Detailed(TOKEN_ADDRESS)
    WHALE = accounts.at(WHALE_ADDRESS, force=True) ## Address with tons of token

    token.transfer(deployer, token.balanceOf(WHALE)/4, {"from": WHALE})
    return token




@pytest.fixture
def strategist():
    return accounts[1]


@pytest.fixture
def keeper():
    return accounts[2]


@pytest.fixture
def guardian():
    return accounts[3]


@pytest.fixture
def governance():
    return accounts[4]

@pytest.fixture
def treasury():
    return accounts[5]


@pytest.fixture
def proxyAdmin():
    return accounts[6]


@pytest.fixture
def randomUser():
    return accounts[7]

@pytest.fixture
def badgerTree():
    return accounts[8]



@pytest.fixture
def deployed(want, deployer, strategist, keeper, guardian, governance, proxyAdmin, randomUser, badgerTree):
    """
    Deploys, vault and test strategy, mock token and wires them up.
    """
    want = want

    vault = TheVault.deploy({"from": deployer})
    vault.initialize(
        want,
        governance,
        keeper,
        guardian,
        governance,
        strategist,
        badgerTree,
        "",
        "",
        [
            PERFORMANCE_FEE_GOVERNANCE,
            PERFORMANCE_FEE_STRATEGIST,
            WITHDRAWAL_FEE,
            MANAGEMENT_FEE,
        ],
    )
    vault.setStrategist(deployer, {"from": governance})
    # NOTE: TheVault starts unpaused

    strategy = ConvexCrvOptimizer.deploy({"from": deployer})
    strategy.initialize(vault, [want], 50);
    # NOTE: Strategy starts unpaused

    vault.setStrategy(strategy, {"from": governance})

    ## Grant contract access from strategy to cvxCRV Helper Vault
    # cvxCrvHelperVault = interface.IVault("0x2B5455aac8d64C14786c3a29858E43b5945819C0")
    # cvxCrvHelperGov = accounts.at(cvxCrvHelperVault.governance(), force=True)
    # cvxCrvHelperVault.approveContractAccess(strategy.address, {"from": cvxCrvHelperGov})

    ## Grant contract access from strategy to CVX Helper Vault
    # cvxHelperVault = interface.IVault("0xfd05D3C7fe2924020620A8bE4961bBaA747e6305")
    # cvxHelperGov = accounts.at(cvxHelperVault.governance(), force=True)
    # cvxHelperVault.approveContractAccess(strategy.address, {"from": cvxHelperGov})

    ## Reset rewards if they are set to expire within the next 4 days or are expired already
    rewardsPool = interface.IBaseRewardsPool(strategy.baseRewardsPool())
    if rewardsPool.periodFinish() - int(time.time()) < days(4):
        booster = interface.IBooster("0xF403C135812408BFbE8713b5A23a04b3D48AAE31")
        booster.earmarkRewards(0, {"from": deployer})
        console.print("[green]BaseRewardsPool expired or expiring soon - it was reset![/green]")

    return DotMap(
        deployer=deployer,
        vault=vault,
        strategy=strategy,
        want=want,
        governance=governance,
        proxyAdmin=proxyAdmin,
        randomUser=randomUser,
        performanceFeeGovernance=PERFORMANCE_FEE_GOVERNANCE,
        performanceFeeStrategist=PERFORMANCE_FEE_STRATEGIST,
        withdrawalFee=WITHDRAWAL_FEE,
        managementFee=MANAGEMENT_FEE,
        badgerTree=badgerTree
    )


## Contracts ##
@pytest.fixture
def vault(deployed):
    return deployed.vault


@pytest.fixture
def strategy(deployed):
    return deployed.strategy



@pytest.fixture
def tokens(deployed):
    return [deployed.want]

### Fees ###
@pytest.fixture
def performanceFeeGovernance(deployed):
    return deployed.performanceFeeGovernance


@pytest.fixture
def performanceFeeStrategist(deployed):
    return deployed.performanceFeeStrategist


@pytest.fixture
def withdrawalFee(deployed):
    return deployed.withdrawalFee


@pytest.fixture
def setup_share_math(deployer, vault, want, governance):

    depositAmount = int(want.balanceOf(deployer) * 0.5)
    assert depositAmount > 0
    want.approve(vault.address, MaxUint256, {"from": deployer})
    vault.deposit(depositAmount, {"from": deployer})

    vault.earn({"from": governance})

    return DotMap(depositAmount=depositAmount)


## Forces reset before each test
@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass
