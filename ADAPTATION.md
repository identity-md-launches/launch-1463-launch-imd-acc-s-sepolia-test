# Sepolia test run 6 launch adaptation

## Changes

| File | Change and reason |
| --- | --- |
| `test/RegistryLaunchRun6.t.sol` | Added an offline CREATE2 rehearsal driven by the existing `launch.json`. The historical factory test deploys a Stacker and registry together; this launch must deploy only ProjectRegistry, using run 2's existing Stacker. The new test pins all seven supplied constructor arguments, deploys the built bytecode with zero ETH on an empty Sepolia chain, checks the predicted address and stored configuration, and records deployment accesses to require exactly one creation with no external constructor calls, code checks or initializer. It also checks both callback selectors, absence of an `owner()` interface, initcode/runtime limits and forbidden runtime opcodes. |
| `README.md` | Documented run 6 as prepared and awaiting the confirmed deployment address, with the exact dependencies and version 3.1 clarification. Corrected this branch's manifest description and test counts and documented the fork-test command. The confirmed address is a post-deployment handoff item, not a local rehearsal address. |
| `ADAPTATION.md` | Added this required record of changes, validation and remaining deployment work. |

## Production code and manifest

No production source changes were needed. `src/ProjectRegistry.sol` already contains version 3.1 of the trader rule: reject the router itself; accept the address its `msgSender()` reports even when that address is a contract. The existing `RegistryPolicyRevisionTest` checks this wording in both application and challenge questions. `RegistryBodyPropertiesTest` checks the eight definitions, their 512-byte bounds and the JSON envelope.

`src/ProjectRegistry.sol`, `src/oracle/OracleAttestation.sol`, `src/Stacker.sol` and `launch.json` are unchanged. The registry has a nonpayable constructor with seven static arguments, no owner and no constructor dependency calls. Only ProjectRegistry is in the manifest; no Stacker, TestIMD, TestSIMD or trial contract is added to the launch. Configuration, dependencies and workflow files are unchanged.

The pinned oracle reference was checked against the existing consumer. The attestation fields, type hash, domain and callback ABI retain protocol conformance. The project's existing ECDSA-first verification, followed by ERC-1271, supports signer keys with EIP-7702 delegation and is preserved. The brief's ownerless, immutable registry and Intake v2 failure callback take precedence over the generic reference's owner-settable example. Failure clears only the registry's own open question and refunds its bond; it does not list or delist a project. Sepolia's supplied callback allowance is 1,000,000 gas; the existing offline callback tests also exercise the 200,000-gas mainnet budget.

The imported audit reported **no findings**. There were no imported findings to reproduce, dismiss or fix, and this adaptation makes no behavioral fixes.

## Validation

Run with Foundry 1.8.3 and the unmodified project configuration: Solidity 0.8.26, Cancun, 10,000 optimizer runs and `bytecode_hash = "none"`.

- `forge build`: passed. ProjectRegistry runtime is 23,295 bytes, below the 24,576-byte EIP-170 limit. Creation bytecode is 24,874 bytes, or 25,098 bytes including its seven argument words, below the 49,152-byte initcode limit. No external library linking is required.
- `env -u ETH_RPC_URL -u SEPOLIA_RPC_URL forge test`: **233 passed, 0 failed, 14 skipped (247 total)** across 38 suites. The skips are the 12 RPC-dependent fork tests and two mainnet-manifest checks. The new exact-manifest factory test passed with all existing offline tests.
- `ETH_RPC_URL=https://ethereum-rpc.publicnode.com SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com forge test --match-path 'test/*Fork.t.sol' -vv`: all 12 existing fork tests passed. These include application/payment through the real Intake v2 on a local Sepolia fork, and the live run 2 Stacker's behavior with its existing test tokens.
- The existing protocol-vector, owner-only applicant, policy revision, callback gas, cooldown, beneficiary handoff, deferred bond, fuzz and invariant tests are retained. No new dependency or network access is needed for the offline tests. Slither and Mythril were not run.

## Deployment handoff

The deployment service must deploy the single manifest entry on Sepolia (11155111). This worker prepared and rehearsed the launch; it did not broadcast a transaction. There is no confirmed run 6 address in the supplied inputs. Once the service returns the confirmed registry address and transaction, add that address to README's Deployments table as **Sepolia test run 6**. Existing live deployment addresses remain historical facts.

The brief's approximately 36.7M Sepolia deployment-gas estimate still needs the deployment service's simulation against its current factory and gas ceiling. Local Cancun execution gas is not a substitute for that simulation. The real panel trial and source verification follow deployment; the previous 11-of-11 rehearsal is not a new live run 6 result.
