// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { RequestConductor } from "../../src/conductor/RequestConductor.sol";
import { HubWarehouseConductor } from "../../src/conductor/HubWarehouseConductor.sol";
import { ITurnstile } from "../../src/turnstile/ITurnstile.sol";
import { TransitTokenLib } from "../../src/helpers/TransitTokenLib.sol";
import { WarehouseConductorUnitBase } from "./WarehouseConductorUnitBase.t.sol";

contract HubWarehouseConductorUnitTest is WarehouseConductorUnitBase {

    function _withdrawalAction(address owner, uint256 amount) internal returns (ITurnstile.WithdrawalAction memory) {
        return ITurnstile.WithdrawalAction({
            ownerChainId: HUB_CHAIN_ID,
            owner: owner,
            to: owner,
            assetId: TransitTokenLib.formatAssetId(HUB_CHAIN_ID, address(usdc)),
            amount: amount,
            deadline: type(uint256).max,
            partiallyFillable: true,
            salt: bytes32(++withdrawSalt)
        });
    }

    function _withdraw(ITurnstile.WithdrawalAction memory req, bytes memory sig) internal {
        ITurnstile.Action[] memory actions = new ITurnstile.Action[](1);
        actions[0] = ITurnstile.Action({
            actionType: ITurnstile.ActionType.Withdrawal, data: abi.encode(req), fare: 0, messageGas: 0
        });
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;
        turnstile.facilitate(actions, sigs);
    }

    function _sign(ITurnstile.WithdrawalAction memory req, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, turnstile.hashWithdrawalAction(req));
        return abi.encodePacked(r, s, v);
    }

    // ---------------------------------------------------------------- depot auth

    function testOnlyWarehouseCanMint() public {
        ITurnstile.DepositMessage memory message = ITurnstile.DepositMessage({
            asset: address(usdc),
            amount: 1e6,
            fromAccountId: TransitTokenLib.formatAccountId(HUB_CHAIN_ID, mallory, false),
            toAccountId: TransitTokenLib.formatAccountId(HUB_CHAIN_ID, mallory, false),
            salt: bytes32(uint256(1))
        });
        bytes memory payload = abi.encode(ITurnstile.ActionType.Deposit, abi.encode(message));
        vm.prank(mallory);
        vm.expectRevert();
        turnstile.receiveMessage(HUB_CHAIN_ID, payload);

        vm.prank(mallory);
        vm.expectRevert();
        hubWarehouseConductor.receiveDeposit(
            HUB_CHAIN_ID, message.asset, message.amount, message.fromAccountId, message.toAccountId
        );
    }

    // ---------------------------------------------------------------- withdraw

    function testWithdrawWithValidSignature() public {
        _deposit(alice, 100e6);
        ITurnstile.WithdrawalAction memory req = _withdrawalAction(alice, 100e6);

        bytes memory sig = _sign(req, alicePk);

        vm.prank(backend);
        _withdraw(req, sig);

        assertEq(
            depot.balanceOf(
                TransitTokenLib.formatAccountId(HUB_CHAIN_ID, alice, false),
                TransitTokenLib.formatAssetId(HUB_CHAIN_ID, address(usdc))
            ),
            0,
            "withdraw: depot balance not burned"
        );
        assertEq(usdc.balanceOf(alice), 100e6, "withdraw: alice did not receive usdc back");
        assertEq(usdc.balanceOf(vault), 0, "withdraw: vault did not release usdc");
    }

    function testWithdrawWithWrongSignerReverts() public {
        _deposit(alice, 100e6);
        ITurnstile.WithdrawalAction memory req = _withdrawalAction(alice, 100e6);
        (, uint256 wrongPk) = makeAddrAndKey("notTheSigner");
        bytes memory sig = _sign(req, wrongPk);

        vm.prank(backend);
        vm.expectRevert(RequestConductor.NotEffective.selector);
        _withdraw(req, sig);
    }

    function testWithdrawReplayReverts() public {
        _deposit(alice, 200e6);
        ITurnstile.WithdrawalAction memory req = _withdrawalAction(alice, 100e6);
        bytes memory sig = _sign(req, alicePk);

        vm.prank(backend);
        _withdraw(req, sig);

        vm.prank(backend);
        vm.expectRevert(RequestConductor.RequestReplay.selector);
        _withdraw(req, sig);
    }

    function testWithdrawBySomeoneElseReverts() public {
        _deposit(alice, 100e6);
        ITurnstile.WithdrawalAction memory req = _withdrawalAction(alice, 100e6);

        bytes memory sig = _sign(req, alicePk);

        vm.prank(mallory);
        vm.expectRevert();
        _withdraw(req, sig);
    }

}
