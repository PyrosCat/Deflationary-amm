// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AMMLiquidityPool} from "../contracts/AMMLiquidityPool.sol";
import {StakedTokenLP} from "../contracts/tokens/StakedTokenLP.sol";
import {DeflationaryToken} from "../contracts/tokens/DeflationaryToken.sol";
import {FlatRateBurnController} from "../contracts/tokens/FlatRateBurnController.sol";

/// @notice Deploys the full system in the required order and wires it up.
///         Encodes the runbook from docs/design/ARCHITECTURE.md section 4.
///
///         The token launches with its tax controller DISABLED (address(0))
///         to avoid the chicken-and-egg where the controller wants addresses
///         that don't exist yet. This script schedules the controller behind
///         the token's 1-day timelock; a follow-up `ActivateController` run
///         executes it after the delay.
///
/// Usage:
///   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify
contract Deploy is Script {
    function run()
        external
        returns (
            DeflationaryToken token,
            FlatRateBurnController controller,
            StakedTokenLP lp,
            AMMLiquidityPool pool
        )
    {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("POOL_OWNER");
        string memory name = vm.envString("TOKEN_NAME");
        string memory symbol = vm.envString("TOKEN_SYMBOL");
        uint256 supply = vm.envUint("TOKEN_INITIAL_SUPPLY");
        uint256 burnRateBps = vm.envUint("INITIAL_BURN_RATE_BPS");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        // 1. Token, tax OFF (controller = address(0)); deployer holds supply.
        token = new DeflationaryToken(name, symbol, supply, deployer, address(0));

        // 2. Burn controller.
        controller = new FlatRateBurnController(burnRateBps);

        // 3. LP share token.
        lp = new StakedTokenLP(string.concat(name, " LP"), string.concat(symbol, "-LP"));

        // 4-5. Pool implementation, then the ERC1967 proxy carrying initialize().
        //      NOTE: token1 is a placeholder here (paired against the token
        //      itself is invalid). Set POOL_TOKEN1 and swap this in for a real
        //      pair; left explicit so deployment can't silently pick a wrong pair.
        address token1 = vm.envOr("POOL_TOKEN1", address(0));
        require(token1 != address(0) && token1 != address(token), "SET_POOL_TOKEN1_TO_A_REAL_PAIR");

        AMMLiquidityPool impl = new AMMLiquidityPool();
        bytes memory init = abi.encodeCall(
            AMMLiquidityPool.initialize, (address(token), token1, address(lp), owner)
        );
        pool = AMMLiquidityPool(address(new ERC1967Proxy(address(impl), init)));

        // 6. One-shot: bind the LP minter to the POOL PROXY. Irreversible.
        lp.setMinter(address(pool));

        // 7. Exempt the pool so swaps don't stack the token tax on top of the
        //    pool's own fee-split burn.
        controller.setExempt(address(pool), true);

        // 8. Schedule the controller behind the token's 1-day timelock.
        //    Run ActivateController after the delay to turn the tax on.
        token.scheduleControllerUpdate(address(controller));

        vm.stopBroadcast();

        console2.log("DeflationaryToken:     ", address(token));
        console2.log("FlatRateBurnController:", address(controller));
        console2.log("StakedTokenLP:         ", address(lp));
        console2.log("Pool implementation:   ", address(impl));
        console2.log("Pool proxy (USE THIS): ", address(pool));
        console2.log("");
        console2.log("Next: transfer ownership to a multisig, then after 1 day run");
        console2.log("      script/ActivateController.s.sol to enable the tax.");
    }
}

/// @notice Second-stage run: execute the timelocked controller update once the
///         1-day delay from Deploy has elapsed.
/// Usage:
///   TOKEN_ADDRESS=0x... forge script script/ActivateController.s.sol \
///     --rpc-url $RPC_URL --broadcast
contract ActivateController is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        DeflationaryToken token = DeflationaryToken(vm.envAddress("TOKEN_ADDRESS"));

        vm.startBroadcast(pk);
        token.executeControllerUpdate();
        vm.stopBroadcast();

        console2.log("Controller activated:", address(token.burnController()));
    }
}
