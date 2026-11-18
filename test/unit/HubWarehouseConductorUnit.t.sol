// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { RequestConductor } from "../../src/conductor/RequestConductor.sol";
import { HubWarehouseConductor } from "../../src/conductor/HubWarehouseConductor.sol";
import { ITurnstile } from "../../src/interfaces/ITurnstile.sol";
import { TransitAddressLib } from "../../src/helpers/TransitAddressLib.sol";
import { WarehouseConductorUnitBase } from "./WarehouseConductorUnitBase.t.sol";
import { IRequestConductor } from "../../src/interfaces/IRequestConductor.sol";

contract HubWarehouseConductorUnitTest is WarehouseConductorUnitBase {

    function _withdrawalAction(address owner, uint256 amount) internal returns (ITurnstile.WithdrawalAction memory) {
        return ITurnstile.WithdrawalAction({
            ownerChainId: HUB_CHAIN_ID,
            owner: owner,
            to: owner,
            assetChainId: HUB_CHAIN_ID,
            asset: address(usdc),
            amount: amount,
            deadline: type(uint256).max,
            partiallyFillable: true,
            dependsOn: bytes32(0),
            salt: bytes32(++withdrawSalt)
        });
    }

    function _withdraw(ITurnstile.WithdrawalAction memory req, bytes memory sig) internal {
        ITurnstile.Action[] memory actions = new ITurnstile.Action[](1);
        actions[0] = ITurnstile.Action({
            actionType: ITurnstile.ActionType.Withdrawal, data: abi.encode(req), bridgeFee: 0, messageGas: 0
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
            fromAccountId: TransitAddressLib.formatTransitAddress(HUB_CHAIN_ID, mallory),
            toAccountId: TransitAddressLib.formatTransitAddress(HUB_CHAIN_ID, mallory),
            facilitationFee: 0,
            feeReceiverAccountId: bytes28(0),
            salt: bytes32(uint256(1))
        });
        bytes memory payload = abi.encode(ITurnstile.ActionType.Deposit, abi.encode(message));
        vm.prank(mallory);
        vm.expectRevert();
        turnstile.receiveMessage(HUB_CHAIN_ID, payload);

        vm.prank(mallory);
        vm.expectRevert();
        hubWarehouseConductor.receiveDeposit(
            HUB_CHAIN_ID, message.asset, message.amount, message.fromAccountId, message.toAccountId, 0, bytes28(0)
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
                TransitAddressLib.formatTransitAddress(HUB_CHAIN_ID, alice),
                TransitAddressLib.formatTransitAddress(HUB_CHAIN_ID, address(usdc))
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
        vm.expectRevert(IRequestConductor.NotEffective.selector);
        _withdraw(req, sig);
    }

    function testWithdrawReplayReverts() public {
        _deposit(alice, 200e6);
        ITurnstile.WithdrawalAction memory req = _withdrawalAction(alice, 100e6);
        bytes memory sig = _sign(req, alicePk);

        vm.prank(backend);
        _withdraw(req, sig);

        vm.prank(backend);
        vm.expectRevert(IRequestConductor.RequestReplay.selector);
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
