// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RegistryBase} from "./ProjectRegistry.t.sol";
import {ProjectRegistry} from "src/ProjectRegistry.sol";
import {OracleAttestation, OracleAttestationConsumer} from "src/oracle/OracleAttestation.sol";
import {Registry1271Signer, RegistrySignerRejectingCode} from "./mocks/Registry1271Signer.sol";

/// @notice Exercise both verification paths through the real registry callback. The protocol
/// vector remains in OracleConsumerConformance.t.sol; these tests cover signer behavior and
/// failure atomicity that a plain signing key cannot reach.
contract RegistrySignerCompatibilityTest is RegistryBase {
    Registry1271Signer internal contractSigner;
    bytes internal constant CONTRACT_SIGNATURE = hex"019a44ff02";

    function setUp() public override {
        vm.chainId(11_155_111);
        super.setUp();
    }

    function test_codeAddedToEOASignerDoesNotInvalidateItsSignedAnswer() public {
        bytes32 id = _apply();
        OracleAttestation.Attestation memory a = _attestation(true);
        bytes memory signature = _sign(a, SIGNER_KEY);
        _addCodeToEOASigner();
        assertTrue(intake.deliver(id, a, signature, 200_000));
        assertTrue(reg.isListed(project));
        assertTrue(reg.consumed(a.requestId));
        assertEq(reg.projectOfIntake(id), address(0));
    }

    function test_codeBearingEOASignerCanDelistAndRefund() public {
        _addCodeToEOASigner();
        _listed();
        bytes32 id = _challenge();
        uint256 balance = imd.balanceOf(challenger);
        assertTrue(_answer(id, false));
        assertFalse(reg.isListed(project));
        assertEq(imd.balanceOf(challenger), balance + BOND);
        assertEq(imd.balanceOf(address(reg)), 0);
    }

    function test_codeBearingEOASignerStillRejectsWrongKeyWithoutConsumingAnswer() public {
        _addCodeToEOASigner();
        _listed();
        bytes32 id = _challenge();
        OracleAttestation.Attestation memory a = _attestation(true);
        _reject(id, a, _sign(a, SIGNER_KEY + 1), OracleAttestationConsumer.BadSignature.selector);
        assertTrue(intake.deliver(id, a, _sign(a, SIGNER_KEY), 200_000));
        assertEq(imd.balanceOf(beneficiary), BOND);
    }

    function test_contractSignerOpaqueSignatureCanDefend() public {
        bytes32 id = _contractChallenge();
        OracleAttestation.Attestation memory a = _attestation(true);
        _approve(a);
        uint64 cooldown = reg.projectOf(project).challengeOpenAt;
        assertTrue(intake.deliver(id, a, CONTRACT_SIGNATURE, 200_000));
        assertTrue(reg.isListed(project));
        assertEq(reg.projectOf(project).challengeOpenAt, cooldown);
        assertEq(imd.balanceOf(beneficiary), BOND);
        assertEq(imd.balanceOf(address(reg)), 0);
        assertTrue(reg.consumed(a.requestId));
    }

    function test_contractSignerOpaqueSignatureCanDelist() public {
        bytes32 id = _contractChallenge();
        OracleAttestation.Attestation memory a = _attestation(false);
        _approve(a);
        uint256 balance = imd.balanceOf(challenger);
        vm.roll(block.number + 1);
        assertTrue(intake.deliver(id, a, CONTRACT_SIGNATURE, 200_000));
        assertFalse(reg.isListed(project));
        assertEq(reg.projectOf(project).toBlock, block.number);
        assertEq(imd.balanceOf(challenger), balance + BOND);
        assertEq(imd.balanceOf(address(reg)), 0);
    }

    function test_malformedContractSignerResponsesCannotReleaseChallengeBond() public {
        bytes32 id = _contractChallenge();
        OracleAttestation.Attestation memory a = _attestation(false);
        _approve(a);
        for (uint8 response = 1; response <= uint8(Registry1271Signer.Mode.WriteState); ++response) {
            contractSigner.setMode(Registry1271Signer.Mode(response));
            _reject(id, a, CONTRACT_SIGNATURE, OracleAttestationConsumer.BadSignature.selector);
        }
        assertEq(contractSigner.writes(), 0, "ERC-1271 runs statically");
        contractSigner.setMode(Registry1271Signer.Mode.Valid);
        assertTrue(intake.deliver(id, a, CONTRACT_SIGNATURE, 200_000));
        assertFalse(reg.isListed(project));
    }

    function test_contractSignerRequiresApprovedDigestAndSignature() public {
        bytes32 id = _contractChallenge();
        OracleAttestation.Attestation memory a = _attestation(true);
        _approve(a);
        _reject(id, a, hex"019a44ff03", OracleAttestationConsumer.BadSignature.selector);
        a.answer = abi.encode(false);
        _reject(id, a, CONTRACT_SIGNATURE, OracleAttestationConsumer.BadSignature.selector);
        a.answer = abi.encode(true);
        assertTrue(intake.deliver(id, a, CONTRACT_SIGNATURE, 200_000));
        assertEq(imd.balanceOf(beneficiary), BOND);
    }

    function test_contractSignerApprovalForAnotherConsumerCannotSettle() public {
        bytes32 id = _contractChallenge();
        OracleAttestation.Attestation memory a = _attestation(true);
        ProjectRegistry other = new ProjectRegistry(
            address(intake), address(imd), STACKER, address(contractSigner), 1, BOND, COOLDOWN
        );
        contractSigner.approve(other.attestationDigest(a), CONTRACT_SIGNATURE);
        _reject(id, a, CONTRACT_SIGNATURE, OracleAttestationConsumer.BadSignature.selector);
        _approve(a);
        assertTrue(intake.deliver(id, a, CONTRACT_SIGNATURE, 200_000));
    }

    function test_revokedContractSignatureCanBeExpiredAfterFailedDelivery() public {
        bytes32 id = _contractChallenge();
        OracleAttestation.Attestation memory a = _attestation(true);
        _approve(a);
        contractSigner.setMode(Registry1271Signer.Mode.WrongMagic);
        uint256 balance = imd.balanceOf(challenger);
        assertFalse(intake.deliver(id, a, CONTRACT_SIGNATURE, 200_000));
        assertFalse(reg.consumed(a.requestId));
        assertEq(reg.projectOfIntake(id), project);
        assertEq(imd.balanceOf(address(reg)), BOND);

        // Intake completed the request despite its callback reverting; no one waits a day.
        vm.prank(applicant);
        reg.expire(project);
        assertTrue(reg.isListed(project));
        assertEq(imd.balanceOf(challenger), balance + BOND);
        assertEq(imd.balanceOf(beneficiary), 0);
        assertEq(reg.projectOfIntake(id), address(0));
        assertEq(imd.balanceOf(address(reg)), 0);
    }

    function test_contractApprovalCannotBypassPanelPolicyOrRequestAuthentication() public {
        bytes32 id = _contractChallenge();
        OracleAttestation.Attestation memory a = _attestation(true);
        a.agreed = 10;
        _approve(a);
        _reject(id, a, CONTRACT_SIGNATURE, ProjectRegistry.WrongPanel.selector);

        a.agreed = 11;
        _approve(a);
        vm.prank(applicant);
        vm.expectRevert(ProjectRegistry.NotIntake.selector);
        reg.onOracleResult(id, a, CONTRACT_SIGNATURE);
        assertEq(reg.projectOfIntake(id), project);
        assertFalse(reg.consumed(a.requestId));
        assertTrue(intake.deliver(id, a, CONTRACT_SIGNATURE, 200_000));
    }

    function _addCodeToEOASigner() internal {
        vm.etch(vm.addr(SIGNER_KEY), address(new RegistrySignerRejectingCode()).code);
        assertGt(reg.oracleSigner().code.length, 0);
    }

    function _contractChallenge() internal returns (bytes32 id) {
        contractSigner = new Registry1271Signer();
        reg = new ProjectRegistry(
            address(intake), address(imd), STACKER, address(contractSigner), 1, BOND, COOLDOWN
        );
        vm.prank(applicant);
        imd.approve(address(reg), type(uint256).max);
        vm.prank(challenger);
        imd.approve(address(reg), type(uint256).max);
        id = _apply();
        OracleAttestation.Attestation memory a = _attestation(true);
        _approve(a);
        assertTrue(intake.deliver(id, a, CONTRACT_SIGNATURE, 200_000));
        assertTrue(reg.isListed(project));
        id = _challenge();
    }

    function _approve(OracleAttestation.Attestation memory a) internal {
        contractSigner.approve(reg.attestationDigest(a), CONTRACT_SIGNATURE);
    }

    function _reject(
        bytes32 id,
        OracleAttestation.Attestation memory a,
        bytes memory signature,
        bytes4 errorSelector
    ) internal {
        bytes32 beforeState = _stateHash();
        vm.prank(address(intake));
        vm.expectRevert(errorSelector);
        reg.onOracleResult{gas: 200_000}(id, a, signature);
        assertEq(_stateHash(), beforeState, "invalid verification is atomic");
        assertEq(reg.projectOfIntake(id), project);
        assertFalse(reg.consumed(a.requestId));
    }

    function _stateHash() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                reg.projectOf(project),
                imd.balanceOf(address(reg)),
                imd.balanceOf(challenger),
                imd.balanceOf(beneficiary),
                reg.bondOwed(challenger),
                reg.bondOwed(beneficiary)
            )
        );
    }
}
