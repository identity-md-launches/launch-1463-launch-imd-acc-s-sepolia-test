// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ProjectRegistry} from "src/ProjectRegistry.sol";
import {OracleAttestation} from "src/oracle/OracleAttestation.sol";
import {MockIntake, MockProject} from "./mocks/MockIntake.sol";
import {RegistryPayoutToken} from "./mocks/RegistryPayoutToken.sol";

/// @dev Unlike the normal-token accounting campaign, this ledger includes unpaid liabilities.
/// Entitlements come from the challenge inputs and outcome, never the observed token balances
/// or bondOwed getter. All actors have a fixed initial balance; there is no minting while fuzzing.
contract DeferredBondHandler is Test {
    uint256 internal constant KEY = 0xA11CE;
    uint256 public constant BOND = 5e18;
    uint256 public constant FUNDS = 1_000_000e18;
    uint256 public constant ACTORS = 5;
    uint256 public constant PROJECTS = 3;

    struct Listing {
        address beneficiary;
        address challenger;
        bytes32 id;
        uint64 askedAt;
        uint64 challengeOpenAt;
        uint64 handoffOpenAt;
        bool listed;
    }

    ProjectRegistry public immutable registry;
    RegistryPayoutToken public immutable token;
    MockIntake public immutable intake;
    address[5] public actors;
    address[3] public projects;
    Listing[3] internal listings;
    mapping(address => uint256) public expectedDebt;
    mapping(address => uint256) public expectedFunds;
    mapping(address => RegistryPayoutToken.Mode) internal expectedMode;

    uint256 public fees;
    uint256 public donations;
    uint256 public posted;
    uint256 public paidAtSettlement;
    uint256 public deferred;
    uint256 public claimed;
    uint256 public failedClaims;
    uint256 public successfulClaims;
    uint256 public lockedHandoffs;
    uint256[6] public outcomes;
    uint256 internal nonce;

    constructor(ProjectRegistry registry_, RegistryPayoutToken token_, MockIntake intake_) {
        registry = registry_;
        token = token_;
        intake = intake_;
        for (uint256 i; i < ACTORS; ++i) {
            address actor = makeAddr(string.concat("deferred bond actor ", vm.toString(i)));
            actors[i] = actor;
            token.mint(actor, FUNDS);
            expectedFunds[actor] = FUNDS;
        }
        for (uint256 i; i < PROJECTS; ++i) {
            projects[i] = address(new MockProject());
            listings[i].beneficiary = actors[i];
            _list(i, actors[4]);
        }
    }

    function openChallenge(uint256 projectSeed, uint256 actorSeed) external {
        uint256 index = projectSeed % PROJECTS;
        Listing storage p = listings[index];
        if (p.id != bytes32(0)) return;
        address payer = actors[actorSeed % ACTORS];
        if (!p.listed) _list(index, payer);
        if (block.timestamp < p.challengeOpenAt) vm.warp(p.challengeOpenAt);

        uint256 fee = intake.price();
        vm.startPrank(payer);
        token.approve(address(registry), fee + BOND);
        p.id = registry.challengeForBeneficiary(
            projects[index], "Review fee outflow and the resolved trader.", p.beneficiary
        );
        vm.stopPrank();
        p.challenger = payer;
        p.askedAt = uint64(block.timestamp);
        expectedFunds[payer] -= fee + BOND;
        fees += fee;
        posted += BOND;
    }

    /// @dev 0=defense, 1=delist, 2=refused, 3=disagreed, 4=lost callback, 5=timeout.
    function resolve(uint256 projectSeed, uint8 outcomeSeed) external {
        uint256 index = projectSeed % PROJECTS;
        Listing storage p = listings[index];
        bytes32 id = p.id;
        if (id == bytes32(0)) return;
        uint256 outcome = outcomeSeed % 6;
        if (block.timestamp > uint256(p.askedAt) + 1 days) outcome = 5;
        address recipient = outcome == 0 ? p.beneficiary : p.challenger;

        if (outcome < 2) {
            _answer(id, outcome == 0);
            if (outcome == 1) p.listed = false;
        } else if (outcome < 4) {
            assertTrue(
                intake.fail(id, outcome == 2 ? 1 : 2, "disagreed", 200_000),
                "refused payouts must not prevent a failure callback"
            );
        } else {
            if (outcome == 4) {
                intake.completeSilently(id);
            } else if (block.timestamp <= uint256(p.askedAt) + 1 days) {
                vm.warp(uint256(p.askedAt) + 1 days + 1);
            }
            // Expiry is permissionless, but the caller does not acquire the bond.
            vm.prank(actors[(index + 1) % ACTORS]);
            registry.expire(projects[index]);
        }

        if (_refuses(recipient)) {
            expectedDebt[recipient] += BOND;
            deferred += BOND;
        } else {
            expectedFunds[recipient] += BOND;
            paidAtSettlement += BOND;
        }
        ++outcomes[outcome];
        assertEq(registry.projectOfIntake(id), address(0), "settled request must be retired");
        delete p.id;
        delete p.challenger;
    }

    function payoutMode(uint256 actorSeed, uint8 modeSeed) external {
        address actor = actors[actorSeed % ACTORS];
        RegistryPayoutToken.Mode next = RegistryPayoutToken.Mode(modeSeed % 4);
        token.setMode(actor, next);
        expectedMode[actor] = next;
    }

    /// @dev Covers claim-to-self, claim to another debtor, and refused claims. A payout must
    /// clear only msg.sender's accumulated debt, even if its recipient also has debt.
    function claim(uint256 actorSeed, uint256 recipientSeed) external {
        address actor = actors[actorSeed % ACTORS];
        address recipient = actors[recipientSeed % ACTORS];
        uint256 amount = expectedDebt[actor];
        vm.prank(actor);
        if (amount == 0) {
            vm.expectRevert(ProjectRegistry.NothingOwed.selector);
        } else if (expectedMode[recipient] == RegistryPayoutToken.Mode.Revert) {
            vm.expectRevert(
                abi.encodeWithSelector(RegistryPayoutToken.RecipientRefused.selector, recipient)
            );
        } else if (expectedMode[recipient] == RegistryPayoutToken.Mode.False) {
            vm.expectRevert(
                abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token))
            );
        }
        registry.claimBond(recipient);
        if (amount == 0 || _refuses(recipient)) {
            ++failedClaims;
        } else {
            expectedDebt[actor] = 0;
            expectedFunds[recipient] += amount;
            claimed += amount;
            ++successfulClaims;
        }
    }

    function handover(uint256 projectSeed, uint256 actorSeed) external {
        uint256 index = projectSeed % PROJECTS;
        Listing storage p = listings[index];
        if (!p.listed) return;
        address next = actors[actorSeed % ACTORS];
        if (p.id != bytes32(0)) {
            vm.prank(p.beneficiary);
            vm.expectRevert(ProjectRegistry.AskOpen.selector);
            registry.setBeneficiary(projects[index], next);
            ++lockedHandoffs;
            return;
        }
        if (block.timestamp < p.handoffOpenAt) vm.warp(p.handoffOpenAt);
        vm.prank(p.beneficiary);
        registry.setBeneficiary(projects[index], next);
        if (next != p.beneficiary) p.handoffOpenAt = uint64(block.timestamp + 1 days);
        p.beneficiary = next;
        // Existing debt stays with its original recipient, irrespective of this handoff.
    }

    function donate(uint256 actorSeed, uint96 rawAmount) external {
        address actor = actors[actorSeed % ACTORS];
        uint256 amount = bound(rawAmount, 1, 1e18);
        vm.prank(actor);
        assertTrue(token.transfer(address(registry), amount));
        expectedFunds[actor] -= amount;
        donations += amount;
    }

    function reprice(uint96 rawFee) external {
        intake.setPrice(bound(rawFee, 1, 2e18));
    }

    function _list(uint256 index, address payer) internal {
        Listing storage p = listings[index];
        uint256 fee = intake.price();
        vm.startPrank(payer);
        token.approve(address(registry), fee);
        bytes32 id = registry.applyListing(
            projects[index], "Venue", "https://example.org/venue", 50, p.beneficiary
        );
        vm.stopPrank();
        expectedFunds[payer] -= fee;
        fees += fee;
        _answer(id, true);
        p.listed = true;
        p.challengeOpenAt = uint64(block.timestamp + 1 hours);
    }

    function _answer(bytes32 id, bool yes) internal {
        OracleAttestation.Attestation memory a;
        a.requestId = bytes32(++nonce << 128);
        a.chainId = 1;
        a.answer = abi.encode(yes);
        a.panelSize = 15;
        a.quorum = 11;
        a.agreed = 11;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, registry.attestationDigest(a));
        assertTrue(
            intake.deliver(id, a, abi.encodePacked(r, s, v), 200_000),
            "valid signed outcome must settle despite a refused bond transfer"
        );
        assertTrue(registry.consumed(a.requestId));
    }

    function _refuses(address recipient) internal view returns (bool) {
        RegistryPayoutToken.Mode response = expectedMode[recipient];
        return
            response == RegistryPayoutToken.Mode.Revert
                || response == RegistryPayoutToken.Mode.False;
    }

    function assertLiabilities() external view {
        uint256 debt;
        uint256 activeBonds;
        uint256 allFunds = token.balanceOf(address(registry)) + token.balanceOf(intake.TREASURY());
        for (uint256 i; i < ACTORS; ++i) {
            address actor = actors[i];
            assertEq(
                registry.bondOwed(actor), expectedDebt[actor], "debt belongs to original recipient"
            );
            assertEq(token.balanceOf(actor), expectedFunds[actor], "exact per-wallet entitlement");
            assertEq(token.allowance(actor, address(registry)), 0, "exact approval consumed");
            debt += expectedDebt[actor];
            allFunds += token.balanceOf(actor);
        }
        for (uint256 i; i < PROJECTS; ++i) {
            Listing memory p = listings[i];
            ProjectRegistry.Project memory actual = registry.projectOf(projects[i]);
            assertEq(actual.listed, p.listed, "only a signed no delists");
            assertEq(actual.beneficiary, p.beneficiary, "handoff model");
            assertEq(actual.intakeId, p.id, "pending question");
            assertEq(actual.asker, p.challenger, "refund recipient");
            assertEq(actual.challengeOpenAt, p.challengeOpenAt, "defense grants no new cooldown");
            assertEq(uint8(actual.ask), p.id == bytes32(0) ? 0 : 2, "one bond per challenge");
            if (p.id != bytes32(0)) {
                activeBonds += BOND;
                assertEq(registry.projectOfIntake(p.id), projects[i]);
            }
        }
        assertEq(debt + claimed, deferred, "deferred bonds are discharged only once");
        assertEq(
            activeBonds + debt + claimed + paidAtSettlement,
            posted,
            "every posted bond accounted for"
        );
        assertEq(
            token.balanceOf(address(registry)),
            activeBonds + debt + donations,
            "full collateral backing"
        );
        assertEq(token.balanceOf(intake.TREASURY()), fees, "Intake receives only fees");
        assertEq(token.balanceOf(address(intake)), 0);
        assertEq(
            token.allowance(address(registry), address(intake)),
            0,
            "fees cannot expose owed collateral"
        );
        assertEq(token.totalSupply(), ACTORS * FUNDS, "campaign has a fixed supply");
        assertEq(allFunds, ACTORS * FUNDS, "no funds leave tracked holders");
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract RegistryDeferredBondInvariantTest is StdInvariant, Test {
    DeferredBondHandler internal handler;
    ProjectRegistry internal registry;
    RegistryPayoutToken internal token;

    function setUp() public {
        vm.chainId(11_155_111);
        vm.roll(1_000);
        vm.warp(1_700_000_000);
        MockIntake intake = new MockIntake();
        token = new RegistryPayoutToken();
        registry = new ProjectRegistry(
            address(intake),
            address(token),
            address(new MockProject()),
            vm.addr(0xA11CE),
            1,
            5e18,
            3600
        );
        handler = new DeferredBondHandler(registry, token, intake);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.openChallenge.selector;
        selectors[1] = handler.resolve.selector;
        selectors[2] = handler.payoutMode.selector;
        selectors[3] = handler.claim.selector;
        selectors[4] = handler.handover.selector;
        selectors[5] = handler.donate.selector;
        selectors[6] = handler.reprice.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_allPendingAndDeferredBondsRemainBackedAndOwned() public view {
        handler.assertLiabilities();
    }

    /// @dev From any reached state, all open questions can be cleared and every debtor can take
    /// its full entitlement to an accepting wallet. Donations alone remain after draining.
    function afterInvariant() public {
        for (uint256 i; i < 3; ++i) {
            handler.resolve(i, 5);
        }
        for (uint256 i; i < 5; ++i) {
            handler.payoutMode(i, 0);
        }
        for (uint256 i; i < 5; ++i) {
            handler.claim(i, i);
        }
        handler.assertLiabilities();
        assertEq(
            token.balanceOf(address(registry)),
            handler.donations(),
            "all liabilities are recoverable"
        );
        assertEq(handler.claimed(), handler.deferred());
    }

    function test_campaignAccumulatesDebtWithoutSpendingOtherOpenBonds() public {
        handler.payoutMode(0, 1); // beneficiary 0 refuses by reverting
        handler.payoutMode(1, 2); // beneficiary 1 refuses by returning false
        handler.openChallenge(0, 3);
        handler.openChallenge(1, 3);
        handler.openChallenge(2, 4); // keep a third project's bond outstanding during claims
        handler.resolve(0, 0);
        handler.resolve(1, 0);
        _check();
        handler.openChallenge(0, 2);
        handler.handover(0, 4); // cannot change the defended-bond recipient mid-question
        handler.resolve(0, 0);
        _check();
        assertEq(handler.expectedDebt(handler.actors(0)), 10e18);
        assertEq(handler.expectedDebt(handler.actors(1)), 5e18);

        handler.handover(0, 4); // old debt must not follow the new beneficiary
        handler.claim(0, 0); // reverting claim keeps all debt and collateral
        handler.claim(0, 1); // a false-returning receiver also preserves the debt
        handler.claim(4, 4); // new beneficiary cannot take the former beneficiary's debt
        _check();
        handler.payoutMode(1, 3); // empty return data is a successful transfer
        handler.claim(0, 1); // pay a debtor without clearing the recipient's own debt
        _check();
        assertEq(registry.bondOwed(handler.actors(1)), 5e18);
        assertEq(token.balanceOf(address(registry)), 10e18); // one debt plus one open bond
        handler.claim(0, 1); // replay cannot pay twice
        handler.claim(1, 1);
        _check();
        assertEq(handler.failedClaims(), 4);
        assertEq(handler.successfulClaims(), 2);
        assertEq(handler.lockedHandoffs(), 1);
        afterInvariant();
    }

    function test_campaignReachesEverySettlementAndOptionalReturnPath() public {
        for (uint8 outcome; outcome < 6; ++outcome) {
            handler.openChallenge(0, 3);
            // 0 pays beneficiary; every other outcome refunds challenger.
            uint256 recipient = outcome == 0 ? 0 : 3;
            handler.payoutMode(recipient, outcome % 2 == 0 ? 1 : 2);
            handler.resolve(0, outcome);
            _check();
            handler.claim(recipient, recipient); // refused claim must remain collectible
            handler.payoutMode(recipient, 3);
            handler.claim(recipient, recipient); // empty-return payout discharges debt
            _check();
            assertEq(handler.outcomes(outcome), 1);
        }
        handler.reprice(1); // paying a new fee must not draw on existing liabilities
        handler.donate(4, 1);
        handler.openChallenge(1, 4);
        handler.payoutMode(1, 3);
        handler.resolve(1, 0); // empty-return direct payout creates no debt
        _check();
        assertEq(handler.paidAtSettlement(), 5e18);
        assertEq(handler.claimed(), 30e18);
        afterInvariant();
    }

    function _check() internal view {
        handler.assertLiabilities();
    }
}
