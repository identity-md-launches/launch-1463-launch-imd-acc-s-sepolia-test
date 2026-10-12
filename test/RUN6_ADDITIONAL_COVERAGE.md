# Additional Sepolia run 6 tests

These tests extend the accepted launch, policy, application-gate, oracle-vector, and normal-token
accounting tests. They need no fork, network, FFI, environment changes, or additional dependencies.

## Deferred bond accounting

`RegistryDeferredBondInvariant.t.sol` uses three projects and five independently funded actors.
Foundry runs 256 sequences of 96 handler calls, with unexpected reverts treated as failures.
The calls open challenges, settle each outcome, change payout behavior, claim accumulated debt
to different wallets, hand off beneficiaries, donate tokens, and change the oracle fee.

The independent ledger checks after every call that:

- Registry assets equal open challenge bonds, unclaimed debts, and tracked donations.
- Every actor receives exactly its entitlement; a claim clears only the caller's debt.
- Posted bonds equal active bonds plus deferred debts plus completed payments and claims.
- Failed claims preserve debt and collateral. Handoffs cannot transfer historical debt.
- Fees go only to the Intake treasury, with no residual allowance exposing bond collateral.
- Fixed token supply is conserved across all holders.
- Settlement retires the correct request, and defending a challenge grants no new cooldown.

After every sequence, the campaign expires open questions, enables payouts, and claims all debt.
Only donated tokens may remain. Two deterministic campaigns exercise every settlement outcome,
simultaneous debts and open bonds, cumulative claims, a failed claim, a repeated claim, handoff
while a question is open, and payment to a recipient that is itself owed a different debt.

`mocks/RegistryPayoutToken.sol` injects reverting, false-returning, and empty-return transfers.
These are resilience tests, not assertions that the live Sepolia token has these behaviors.
The model assumes successful transfers move exactly their stated amount; it does not claim
support for rebasing, fee-on-transfer, or malicious tokens that report success without paying.

## Signer compatibility and failure isolation

`RegistrySignerCompatibility.t.sol` exercises both signature-verification paths through the
registry's real callback. It checks that code added to an EOA signer does not invalidate that
key's signatures, and that an unrelated key still fails. The code-presence fixture models the
verification branch relevant to EIP-7702; it does not simulate a delegation transaction.

An ERC-1271 fixture authorizes an exact digest and opaque signature. Tests cover listing,
defense, delisting, consumer-domain isolation, approval revocation, wrong magic values, revert,
missing/short/dirty return data, and attempted signer storage writes under STATICCALL. Invalid
callbacks preserve the pending request, collateral, debts, and unconsumed oracle UUID. A failed
delivery can still be expired once Intake has completed it, returning the challenger its bond.
Contract approval does not bypass Intake authentication or panel requirements.

Successful callbacks and explicitly rejected signature checks use the 200,000-gas mainnet
callback budget, which is below run 6's specified Sepolia allowance of 1,000,000 gas. This adds
no new live-state claim: existing optional fork tests still require their RPC configuration.

## Verification

```sh
forge build --offline --out /tmp/imd-run6-out --cache-path /tmp/imd-run6-cache
forge test --offline --out /tmp/imd-run6-out --cache-path /tmp/imd-run6-cache
```

The output overrides keep generated artifacts out of the repository. The tests and their inline
invariant settings are also used by ordinary `forge test`.
