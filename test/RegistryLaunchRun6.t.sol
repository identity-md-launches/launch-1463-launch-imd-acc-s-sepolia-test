// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {ProjectRegistry} from "../src/ProjectRegistry.sol";

/// @dev Test-only bytecode factory: no initialization call and no deployment value.
contract RegistryRun6Factory {
    function deploy(bytes memory initCode, bytes32 salt) external returns (address registry) {
        assembly ("memory-safe") {
            registry := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        require(registry != address(0), "registry deployment failed");
    }
}

/// @notice Rehearse the run 6 manifest itself, rather than the historical two-contract launch.
contract RegistryLaunchRun6Test is Test {
    address constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address constant ORACLE_IMD = 0x44a1Cd38474FB1748400E7DEb5F8D786ccE3F89A;
    address constant STACKER = 0x0457276D7b036818B3EddC1A4A3FCeda61e9314d;
    address constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;

    function test_run6ManifestDeploysOnlyRegistryWithoutExternalConstructorCalls() public {
        vm.chainId(11_155_111);
        string memory json = vm.readFile("./launch.json");
        assertEq(vm.parseJsonString(json, ".kind"), "evm_contracts");
        assertEq(vm.parseJsonString(json, ".contracts[0].contract"), "ProjectRegistry");
        assertFalse(vm.keyExistsJson(json, ".contracts[1]"), "only ProjectRegistry is deployed");
        string[] memory args = vm.parseJsonStringArray(json, ".contracts[0].constructorArgs");
        assertEq(args.length, 7);
        assertEq(vm.parseAddress(args[0]), INTAKE);
        assertEq(vm.parseAddress(args[1]), ORACLE_IMD);
        assertEq(vm.parseAddress(args[2]), STACKER, "reuse launch #1294's Stacker");
        assertEq(vm.parseAddress(args[3]), SIGNER);
        assertEq(vm.parseUint(args[4]), 1);
        assertEq(vm.parseUint(args[5]), 5e18);
        assertEq(vm.parseUint(args[6]), 3600);

        // Static ABI words, just as supplied by the launch factory. The uint64 cooldown
        // occupies the same word as uint256 here, after checking its exact manifest value.
        bytes memory initCode = bytes.concat(
            vm.getCode("ProjectRegistry.sol:ProjectRegistry"),
            abi.encode(
                vm.parseAddress(args[0]),
                vm.parseAddress(args[1]),
                vm.parseAddress(args[2]),
                vm.parseAddress(args[3]),
                vm.parseUint(args[4]),
                vm.parseUint(args[5]),
                vm.parseUint(args[6])
            )
        );
        assertLe(initCode.length, 49_152, "EIP-3860 initcode limit");
        assertEq(INTAKE.code.length, 0);
        assertEq(ORACLE_IMD.code.length, 0);
        assertEq(STACKER.code.length, 0);
        assertEq(SIGNER.code.length, 0);

        RegistryRun6Factory factory = new RegistryRun6Factory();
        bytes32 salt = keccak256("imd/acc Sepolia test run 6 rehearsal");
        address predicted = vm.computeCreate2Address(salt, keccak256(initCode), address(factory));
        vm.startStateDiffRecording();
        ProjectRegistry registry = ProjectRegistry(factory.deploy(initCode, salt));
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertEq(address(registry), predicted);
        _checkDeploymentAccesses(accesses, address(factory), address(registry));

        assertEq(address(registry.intake()), INTAKE);
        assertEq(address(registry.oracleAsset()), ORACLE_IMD);
        assertEq(registry.stacker(), STACKER);
        assertEq(registry.oracleSigner(), SIGNER);
        assertEq(registry.questionChainId(), 1);
        assertEq(registry.challengeBond(), 5e18);
        assertEq(registry.challengeCooldown(), 3600);
        assertEq(address(registry).balance, 0);
        (bool hasOwner,) = address(registry).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(hasOwner, "the factory must not acquire an admin role");
        assertEq(registry.onOracleResult.selector, bytes4(0x510379c7));
        assertEq(registry.onOracleFailure.selector, bytes4(0xa7980e31));
        _checkRuntime(address(registry).code);
    }

    function _checkDeploymentAccesses(
        VmSafe.AccountAccess[] memory accesses,
        address factory,
        address registry
    ) internal pure {
        uint256 creations;
        for (uint256 i; i < accesses.length; ++i) {
            VmSafe.AccountAccess memory a = accesses[i];
            if (a.kind == VmSafe.AccountAccessKind.Create) {
                ++creations;
                assertEq(a.accessor, factory);
                assertEq(a.account, registry);
                assertEq(a.value, 0);
                assertFalse(a.reverted);
            } else if (a.kind != VmSafe.AccountAccessKind.Resume) {
                // The sole call is the test entering the factory. No dependency call,
                // code-presence check, nested creation or initializer is permitted.
                assertEq(uint8(a.kind), uint8(VmSafe.AccountAccessKind.Call));
                assertEq(a.account, factory);
            }
        }
        assertEq(creations, 1, "no Stacker, token, or constructor-created extra contract");
    }

    function _checkRuntime(bytes memory code) internal pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576, "EIP-170 runtime limit");
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
        }
    }
}
