from helpers.StrategyCoreResolver import StrategyCoreResolver
from rich.console import Console
from brownie import interface

console = Console()


class StrategyResolver(StrategyCoreResolver):
    def get_strategy_destinations(self):
        """
        Track balances for all strategy implementations
        (Strategy Must Implement)
        """
        strategy = self.manager.strategy
        sett = self.manager.sett
        return {
            "threeCrv": strategy.THREE_CRV(),
            "usdc": strategy.USDC(),
            "cvx": strategy.CVX(),
            "crv": strategy.CRV(),
            "cvxCrv": strategy.CVXCRV(),
            "bcvxCrv": strategy.BCVXCRV(),
            "bveCvx": strategy.BVECVX(),
            "badgerTree": sett.badgerTree(),
        }

    def add_balances_snap(self, calls, entities):
        super().add_balances_snap(calls, entities)
        strategy = self.manager.strategy

        threeCrv = interface.IERC20(strategy.THREE_CRV())
        usdc = interface.IERC20(strategy.USDC())
        cvx = interface.IERC20(strategy.CVX())
        crv = interface.IERC20(strategy.CRV())
        cvxCrv = interface.IERC20(strategy.CVXCRV())
        bcvxCrv = interface.IERC20(strategy.BCVXCRV())
        bveCvx = interface.IERC20(strategy.BVECVX())

        calls = self.add_entity_balances_for_tokens(calls, "threeCrv", threeCrv, entities)
        calls = self.add_entity_balances_for_tokens(calls, "usdc", usdc, entities)
        calls = self.add_entity_balances_for_tokens(calls, "cvx", cvx, entities)
        calls = self.add_entity_balances_for_tokens(calls, "crv", crv, entities)
        calls = self.add_entity_balances_for_tokens(calls, "cvxCrv", cvxCrv, entities)
        calls = self.add_entity_balances_for_tokens(calls, "bcvxCrv", bcvxCrv, entities)
        calls = self.add_entity_balances_for_tokens(calls, "bveCvx", bveCvx, entities)

        return calls
        
    def confirm_harvest(self, before, after, tx):
        """
        Verfies that the Harvest produced yield and fees
        NOTE: This overrides default check, use only if you know what you're doing
        """
        console.print("=== Compare Harvest ===")
        self.manager.printCompare(before, after)
        self.confirm_harvest_state(before, after, tx)
        strategy = self.manager.strategy

        # Include the default check? 
        super().confirm_harvest(before, after, tx)

        assert len(tx.events["Harvested"]) == 1
        event = tx.events["Harvested"][0]

        assert event["token"] == strategy.want()
        assert event["amount"] == after.get("sett.balance") - before.get("sett.balance")

        valueGained = after.get("sett.getPricePerFullShare") > before.get(
            "sett.getPricePerFullShare"
        )
        assert valueGained

        if before.get("sett.performanceFeeGovernance") > 0:
            assert after.balances("sett", "treasury") > before.balances(
                "sett", "treasury"
            )

        if before.get("sett.performanceFeeStrategist") > 0:
            assert after.balances("sett", "strategist") > before.balances(
                "sett", "strategist"
            )

        assert len(tx.events["TreeDistribution"]) == 1
        event = tx.events["TreeDistribution"][0]

        assert event["token"] == strategy.BVECVX()
        assert event["amount"] > 0

        if before.get("sett.performanceFeeGovernance") > 0:
            assert after.balances("bveCvx", "treasury") > before.balances(
                "bveCvx", "treasury"
            )

        if before.get("sett.performanceFeeStrategist") > 0:
            assert after.balances("bveCvx", "strategist") > before.balances(
                "bveCvx", "strategist"
            )

        # Assert no tokens left behind
        assert after.balances("crv", "strategy") == 0
        assert after.balances("cvx", "strategy") == 0
        assert after.balances("cvxCrv", "strategy") == 0
        assert after.balances("threeCrv", "strategy") == 0
