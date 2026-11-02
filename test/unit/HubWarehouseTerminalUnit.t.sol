// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { HubWarehouseTerminal } from "../../src/terminal/HubWarehouseTerminal.sol";
import { ITurnstile } from "../../src/ITurnstile.sol";
import { TransitTokenLib } from "../../src/helpers/TransitTokenLib.sol";
import { WarehouseTerminalUnitBase } from "./WarehouseTerminalUnitBase.t.sol";

contract HubWarehouseTerminalUnitTest is WarehouseTerminalUnitBase {

    function _request(address owner, uint256 amount) internal returns (HubWarehouseTerminal.WithdrawalRequest memory) {
        return HubWarehouseTerminal.WithdrawalRequest({
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

    function _genericMessage(HubWarehouseTerminal.WithdrawalRequest memory req) internal view returns (ITurnstile.GenericMessage memory) {
        ITurnstile.Call[] memory calls = new ITurnstile.Call[](1);
        calls[0] = ITurnstile.Call({
            target: address(hubWarehouseTerminal), data: abi.encodeCall(HubWarehouseTerminal.executeWithdrawal, (req, 0))
        });
        return ITurnstile.GenericMessage({ sender: req.owner, calls: calls, deadline: req.deadline, salt: req.salt });
    }

    function _withdraw(HubWarehouseTerminal.WithdrawalRequest memory req, bytes memory sig) internal {
        ITurnstile.GenericMessage[] memory calls = new ITurnstile.GenericMessage[](1);
        calls[0] = _genericMessage(req);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;
        uint256[][] memory values = new uint256[][](1);
        values[0] = new uint256[](1);
        turnstile.facilitate(calls, sigs, values);
    }

    function _sign(HubWarehouseTerminal.WithdrawalRequest memory req, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, turnstile.hashGenericMessage(_genericMessage(req)));
        return abi.encodePacked(r, s, v);
    }

    // ---------------------------------------------------------------- depot auth

    function testOnlyWarehouseCanMint() public {
        ITurnstile.DepositMessage memory message = ITurnstile.DepositMessage({ asset: address(usdc), amount: 1e6, toAccountId: TransitTokenLib.formatAccountId(HUB_CHAIN_ID, mallory), salt: bytes32(uint256(1)) });
        bytes memory payload = abi.encode(ITurnstile.MessageType.Deposit, abi.encode(message));
        vm.prank(mallory);
        vm.expectRevert();
        turnstile.receiveMessage(HUB_CHAIN_ID, payload);

        vm.prank(mallory);
        vm.expectRevert();
        hubWarehouseTerminal.receiveDeposit(HUB_CHAIN_ID, message.asset, message.amount, message.toAccountId);
    }

    // ---------------------------------------------------------------- withdraw

    function testWithdrawWithValidSignature() public {
        _deposit(alice, 100e6);
        HubWarehouseTerminal.WithdrawalRequest memory req = _request(alice, 100e6);

        bytes memory sig = _sign(req, alicePk);

        vm.prank(backend);
        _withdraw(req, sig);

        assertEq(depot.balanceOf(TransitTokenLib.formatAccountId(HUB_CHAIN_ID, alice), TransitTokenLib.formatAssetId(HUB_CHAIN_ID, address(usdc))), 0, "withdraw: depot balance not burned");
        assertEq(usdc.balanceOf(alice), 100e6, "withdraw: alice did not receive usdc back");
        assertEq(usdc.balanceOf(vault), 0, "withdraw: vault did not release usdc");
    }

    function testWithdrawWithWrongSignerReverts() public {
        _deposit(alice, 100e6);
        HubWarehouseTerminal.WithdrawalRequest memory req = _request(alice, 100e6);
        (, uint256 wrongPk) = makeAddrAndKey("notTheSigner");
        bytes memory sig = _sign(req, wrongPk);

        vm.prank(backend);
        vm.expectRevert(ITurnstile.BadSignature.selector);
        _withdraw(req, sig);
    }

    function testWithdrawReplayReverts() public {
        _deposit(alice, 200e6);
        HubWarehouseTerminal.WithdrawalRequest memory req = _request(alice, 100e6);
        bytes memory sig = _sign(req, alicePk);

        vm.prank(backend);
        _withdraw(req, sig);

        vm.prank(backend);
        vm.expectRevert(ITurnstile.MessageReplay.selector);
        _withdraw(req, sig);
    }

    function testWithdrawBySomeoneElseReverts() public {
        _deposit(alice, 100e6);
        HubWarehouseTerminal.WithdrawalRequest memory req = _request(alice, 100e6);

        bytes memory sig = _sign(req, alicePk);

        vm.prank(mallory);
        vm.expectRevert();
        _withdraw(req, sig);
    }

}
