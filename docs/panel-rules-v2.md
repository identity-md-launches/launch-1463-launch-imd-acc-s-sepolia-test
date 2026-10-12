# Panel rules, version 2 (draft for the mainnet registry)

The rules (`definitions`) the IdentityMD oracle panel reads when it judges a listing. Version 1 is what the deployed Sepolia ProjectRegistry sends; it is fixed in that contract's code. Version 2 says the same things more plainly, after PLEA's two Sepolia applications split the panel ([history, section 17](history.md#17-registry-trial-pleas-first-applications-2026-10-12)). It was rehearsed once on Sepolia and reached a signed answer ([history, section 18](history.md#18-clearer-panel-rules-rehearsed-2026-10-12)).

**In `src/ProjectRegistry.sol` on `main` since 2026-10-12**, approved by the owner together with IMD's Sepolia fixes, for the mainnet registry. Deployed on Sepolia in test runs 3 and 4 (launches #1371 and #1378); test run 2's registry keeps version 1. A local deployment returns these rules for PLEA's hook character for character as rehearsed.

## The rules

`<project>`, `<rate>` and `<beneficiary>` are filled in by the registry. Each rule must stay at most 512 characters (IMD's limit) and contain no double quote or backslash (the registry writes them into JSON as they are).

| Key | Rule |
|---|---|
| `trading` | `<project>` is a trading venue (for example a Uniswap v4 hook, a pool or a launchpad). Every call it can make to credit(trader, amount) on the Stacker happens while executing a trade, for the trader of that trade, with IMD from the fees of that trade. A wallet, an unverified contract, or a contract that can call credit outside a trade, for wallets it picks, or with IMD that is not from the trade fails this rule. |
| `trader` | The project never chooses who is credited. The trader may be the address the swap caller passes in hookData, as routers do, with the swap sender as the fallback; that address counts as the trader of that trade. |
| `otherPayouts` | Cashback that is not credited through the Stacker is allowed and simply earns no points: for example plain IMD paid when credit reverts, or a payout in another form when crediting is not possible. Such payouts never break the trading or rate rules. |
| `rate` | Each credit is `<rate>` basis points of its trade (100 basis points = 1%), and that rate is between 25 and 100. If the rate can change, the code must keep it between 25 and 100 and `<rate>` must be the rate in force now. |
| `feeGuard` | Split the trading fee into three parts: the cashback; the parts that come back to the owner or team (owner share, treasury, liquidity or reserves the owner or team can withdraw); and the parts that leave for good (burned tokens, prizes paid to others, fees to third parties, locked value as in lockedValue). The parts that leave for good must add up to at least the cashback. If the rate or the fee split can change, the code must keep this true for every allowed setting. |
| `lockedValue` | Liquidity or reserves that no owner or team wallet can ever withdraw count as leaving for good, even if the contract itself can move them between its own positions or pools. |
| `beneficiary` | `<beneficiary>` must be the owner of `<project>`, or a wallet its verified source or its official website names as its team or treasury. (unchanged) |
| `evidence` | Use the verified source published for this address on the chain named in the question, on its block explorer (Etherscan or Blockscout) or on Sourcify; a full or partial match on any one of them is verified source. Use on-chain reads at the latest block. Code with no verified source on any of them, or unreadable code, means false. |

For a challenge, `rate` keeps version 1's challenge form (the rate in force must be within 25-100; the application rate is historical), with the same `otherPayouts` rule.

## What changed from version 1, and why

| Version 1 said | Panel members read it as | Version 2 |
|---|---|---|
| "calls credit … only while executing a trade, for the trader of that trade" | every cashback must be staked, so a plain-IMD fallback (our integration rule 2) or another payout fails | `otherPayouts`: allowed, earns no points |
| "for the trader of that trade" | an address from caller-supplied `hookData` (our integration rule 3) isn't bound to the trader | `trader`: the hookData address counts as the trader |
| "liquidity locked forever" | liquidity the contract can move back into its own reserve isn't locked | `lockedValue`: what no owner or team wallet can ever withdraw leaves for good |
| "the verified source on the block explorer" | Etherscan only; unverified there means false | `evidence`: Etherscan, Blockscout or Sourcify |
| (mainnet condition agreed on 2026-10-11) | | `feeGuard`: true for every allowed setting |

## Results on PLEA's hook (Sepolia, the same question otherwise)

| Rules | Yes | No | Outcome |
|---|---|---|---|
| Version 1, PLEA's first application | 8 | 5 | split, cleared |
| Version 1, PLEA's second application | 9 | 4 | split, cleared |
| Version 2, rehearsal | 11 | 2 | **signed yes** (11 needed) |
| Version 2, test run 4 registry, live application | 11 | 1 | **signed yes: listed** ([history, section 29](history.md#29-live-listing-trial-on-the-test-run-4-registry-plea-listed-and-defended-2026-10-12)) |
| Version 2 (challenge form), live challenge | 11 | 0 | **signed yes: defended** |

With version 2 no member raised the trading, trader, rate or evidence rules. The two "no" answers were about PLEA's own fee split: its owner can enter and win Seasons prizes, and a public `rebalance()` pays a 0.01 IMD keeper tip from the hook's retained IMD to whoever calls it. The margin was exactly the quorum, so one rehearsal is not proof that every panel will agree. The live application on test run 4 again reached exactly 11 yes; its one no was the same keeper tip. The live challenge was unanimous (11 of 11).
