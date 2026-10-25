# OGClubCreatorPool

Pays $OG each month to the developers of the games listed in OG Club World. One Solidity contract
(`src/OGClubCreatorPool.sol`), Foundry tests, and deploy scripts for Sepolia and mainnet.

Built with OpenZeppelin 5 (`Ownable2Step`, `ReentrancyGuard`, `SafeERC20`, `MerkleProof`), Solidity
`^0.8.24` compiled with the pinned `solc = "0.8.26"`, custom errors throughout. No ETH, no `receive`,
no proxy, no `selfdestruct`, no `delegatecall`.

```
forge build
forge test
forge fmt --check
```

## How it works

```
 OGClubFarmVault ── season claim (plain ERC-20 transfer) ──▶ OGClubCreatorPool ── claim(month, game, amount, proof) ──▶ game payout wallet
 anyone ──────────── fund(amount) / plain transfer ─────────▶        │
 owner ───────────── proposeMonth(month, root, total) ──────▶ reserved += total, opens in 3 days, closes 90 days later
 anyone ──────────── sweep(month) after the window ─────────▶ unclaimed returns to free()
```

### Setup

* `constructor(IERC20 token, address owner)`. `token` is immutable and is **not** called in the
  constructor (the launch rehearses constructors on an empty chain). Zero addresses are refused.
* `CLAIM_DELAY = 3 days`, `CLAIM_PERIOD = 90 days`, `FIRST_YEAR = 2026`.

### Games

* `gameId(string kitId)` = `keccak256(bytes(kitId))`, e.g. `gameId("coin-dash")`.
* `games[id] = {payout, listed}`, plus `listedAt[id]` (timestamp of the listing).
* `listGame(id, payout)` — owner only. An id can only ever be listed once; afterwards only
  `delistGame` / `relistGame` (owner only) toggle `listed`. Delisting never stops claims of months
  already proposed. `listed` is informational for the off-chain monthly draft. A game can only claim
  from months proposed **at or after** it was listed: list the games first, then propose the month.
* `changePayout(id, to)` — **only the game's current payout wallet**. The owner can never change a
  payout. `to` may not be zero, the pool itself, the current wallet, the owner or the pending owner.
  Works while delisted.

### Money in

* Plain ERC-20 transfers to the pool count. This is how the farm vault pays it: the pool's address is
  one account of a vault season, and anyone pushes `vault.claim(season, pool, amount, proof)`.
* `fund(amount)` pulls with `safeTransferFrom(msg.sender, …)` and reverts with `BalanceMismatch`
  unless the balance grew by exactly `amount` (fee-on-transfer tokens are rejected; `claim` checks
  both the pool's and the recipient's side the same way).
* `free()` = balance − `reserved`.

### Months

A month id is `YYYYMM`: `month % 100` in 1..12, `year >= 2026` (`isValidMonth`).

* `proposeMonth(month, root, total)` — owner only. `root` and `total` nonzero, `total <= free()`,
  `month > lastMonth`, or `month == lastMonth` when that month was cancelled (then it overwrites it).
  Sets `opensAt = now + 3 days`, `reserved += total`. `lastMonth` is the highest **live** month
  (proposed and not cancelled), or 0; `lastMonthBefore[month]` remembers what it was before each
  proposal.
* `cancelMonth(month)` — owner only, **only before `opensAt`**. Releases the reservation back to
  `free()`. Cancelling the highest month moves `lastMonth` back to the highest live month below it,
  so a mistyped id (`999912`, or `207206` for `202706`) is undone by cancelling it within the three
  days and the intended id can then be proposed. Cancelling a month below a live later month leaves
  `lastMonth` alone. Once a month has opened the owner can never touch its money again.
* `claim(month, game, amount, proof)` — anyone. Open while `opensAt <= now < opensAt + 90 days`.
  Once per game per month. Leaf = `keccak256(bytes.concat(keccak256(abi.encode(month, game, amount))))`
  (OpenZeppelin standard double-hash, sorted pairs). `amount <= remaining`. The game must have a
  payout wallet (delisted is fine) and must have been listed **no later than the month was proposed**
  (`listedAt[game] <= opensAt - 3 days`, otherwise `GameListedAfterProposal`), so the wallets a month
  can pay are fixed when its public review starts. The payout wallet may not be the current owner.
  Pays `games[game].payout`, **never the caller**, and reverts unless the pool's balance fell by
  exactly `amount` **and** the payout wallet's balance rose by exactly `amount`.
* `sweep(month)` — anyone, once `now >= opensAt + 90 days`. The unclaimed remainder goes back to
  `free()` for a later month. Nothing goes to the caller or the owner.
* Views: `status(month)` (`None | Pending | Open | Closed | Swept | Cancelled`), `isOpen(month)`,
  `leaf(month, game, amount)`, `isValidMonth(month)`, `months(month)`, `claimed(month, game)`,
  `listedAt(game)`, `lastMonth()`, `lastMonthBefore(month)`.

### What the owner cannot do

There is no withdraw, rescue or sweep-to-owner path, no token setter, no upgrade. The owner cannot
change a game's payout wallet, cannot be a payout wallet (neither can the pending owner, and a claim
to a wallet that has since become the owner is refused), cannot cancel a month once its 3-day delay
has passed, and cannot add a recipient to a month after proposing it (a game listed later can only
claim from later months). `renounceOwnership()` is disabled: without an owner nobody could propose a
month and the free balance would be stuck. $OG only leaves the contract as claims to game payout
wallets. The owner can: list / delist / relist games, propose months, cancel a month before it
opens, and hand ownership over in two steps.

Trust assumptions: the owner publishes honest Merkle roots and totals. A dishonest root can only
direct money to the payout wallets of games that were **already listed when the month was proposed**;
a leaf for any other id is unclaimable for that month, whatever the owner does afterwards. The
contract cannot tell a game wallet the owner secretly controls from any other wallet: the three-day
review of the published list against the listed games is the safeguard against that. Delisting a
game excludes it from future drafts (off-chain) but not from months already proposed.

## Invariants (tested)

* `token.balanceOf(pool) >= reserved`.
* `reserved == Σ months[m].remaining` over all proposed months (cancel and sweep zero `remaining`).
* The owner's $OG balance never rises through this contract, and the owner is never a payout wallet
  (the handler tries to list it and to move a payout to it; both are refused).
* `lastMonth` is the highest proposed month that is not cancelled, or 0.
* Conservation: pool balance == total funded − total paid to payout wallets.
* Fuzz: a month never pays more than its `total`, whatever the leaves add up to and in any claim
  order; forged leaves and proofs are refused; month-id validation matches the spec for any input.

## Tests

| File | Covers |
| --- | --- |
| `test/OGClubCreatorPool.t.sol` | list/delist/relist/payout rules; owner and pending owner refused as payout, claim refused when a payout became the owner; odd (3, 5, 1) and even (4) leaf counts; anyone can push a claim; payout change before claim pays the new wallet; every revert (early, late, twice, wrong leaf, over budget, bad month, cancel too late, sweep too early, unknown game/month, cancelled month, game listed after the proposal); same-block listing and re-proposal accept the game; cancel and re-propose; cancel restores `lastMonth` (typo, nested, walk-back over cancelled months, never below an open month); sweep then reuse; fee-on-transfer token reverts on `fund` and on `claim` for both the sender-charged and recipient-charged shapes; `renounceOwnership` reverts; owner has no way to take tokens |
| `test/OGClubCreatorPool.fuzz.t.sol` | paid per month ≤ total; forged leaf rejected; month-id validation |
| `test/OGClubCreatorPool.invariant.t.sol` | the six invariants above under a handler that funds, proposes, cancels, claims, sweeps, moves payouts, tries the owner as payout, toggles listings and warps time |
| `test/OGClubCreatorPool.integration.t.sol` | vault season lists the pool → vault claim lands $OG in the pool → pool month pays games |
| `test/DeployScripts.t.sol` | both deploy functions called directly with constants |

Tests read no environment variables and do not depend on the caller address, so they run in any
order and in parallel. Run with the verifier's seed to reproduce exactly:

```
FOUNDRY_FUZZ_SEED=0x48902c4189176b869d01fa4e7721899fadec0269e39c2ae7abc91eada15dee68 forge test
```

### About the vault in the integration test

The brief asks for an integration test with the real `OGClubFarmVault` from the existing OG Club
Foundry project. **This repository was empty when the work started and the vault's source is not
published anywhere reachable**, so the integration test runs against
`test/support/OGClubFarmVault.sol`: a reconstruction of the vault's season interface as the brief
describes it (`openSeason(season, root, total)`, `claim(season, account, amount, proof)` paying
`account`, same leaf scheme). It is test support only, nothing in `src/` depends on it, and it is
not part of the launch. When the real vault source is placed in this repository, replace that one
import in `test/OGClubCreatorPool.integration.t.sol`; the pool-side flow is unchanged because the
pool only sees a plain ERC-20 transfer. The same applies to `OGClubStaking` and `OGClubClubs`,
which the pool does not interact with.

## Deployment

### Mainnet (`script/DeployCreatorPool.s.sol`)

Reads `OG_TOKEN` and `OWNER` from the environment, deploys the pool, lists no games, prints the
address and ABI-encoded constructor args:

```
OG_TOKEN=0x<real $OG> OWNER=0x<owner> \
  forge script script/DeployCreatorPool.s.sol --rpc-url $RPC --account <keystore> --broadcast
forge verify-contract <pool> src/OGClubCreatorPool.sol:OGClubCreatorPool --chain 1 --constructor-args <printed bytes>
```

For the IdentityMD launch this script is reference only: the launch factory deploys the bytecode as
built and the manifest step fills the constructor as `[OG token address, $owner]`. The constructor
takes 2 arguments, calls no contract, and the runtime is ~8.3 KB (under EIP-170).

| Parameter | Value |
| --- | --- |
| `token` | the live $OG token address on the launch chain (requester's value) |
| `owner` | `$owner` = `0x5b95a971b4583a5f011e9da082acdd679b870d06` for this launch |

### Sepolia rehearsal (`script/DeployCreatorPoolSepolia.s.sol`)

Deploys `MockOG` (anyone can mint; mints `MOCK_SUPPLY = 1,000,000 OG` to the broadcaster), the
pool owned by the broadcaster, lists the test games from `GAMES_JSON`, and, if `OWNER` differs from
the broadcaster, starts an `Ownable2Step` handover that `OWNER` must accept. Test game payouts may
not be the broadcaster (listing reverts with `InvalidPayout`) and should not be `OWNER` either: a
game whose payout is the owner cannot claim. JSON format (see
`script/config/sepolia-games.example.json`, replace the placeholders):

```json
[{"kitId": "coin-dash", "payout": "0x…"}, {"kitId": "rocket-run", "payout": "0x…"}]
```

```
GAMES_JSON="$(cat script/config/sepolia-games.json)" OWNER=0x<owner> \
  forge script script/DeployCreatorPoolSepolia.s.sol --rpc-url $SEPOLIA_RPC --account <keystore> --broadcast
```

The JSON is passed as text so the scripts need no `fs_permissions`; `ffi` is off.

## Operations (after launch)

1. **List games.** For each game: `listGame(gameId(kitId), payoutWallet)`. The id is permanent and
   the payout wallet is then the game's to move (`changePayout`). The wallet may not be the owner.
   List a game **before** proposing the first month that pays it: a month only pays games listed no
   later than its proposal, so a game listed mid-review is paid from the next month (or cancel and
   re-propose the current one).
2. **Fund.** Add the pool's address as an account in each `OGClubFarmVault` season (out of scope here),
   then anyone pushes `vault.claim(season, pool, amount, proof)`. Or `fund(amount)` after an approve.
3. **Each month.** Off-chain: measure play, draft the list `[(month, game, amount)]`, build the Merkle
   tree with `leaf = keccak256(bytes.concat(keccak256(abi.encode(month, game, amount))))` and sorted
   pair hashing (OpenZeppelin `StandardMerkleTree` with types `["uint256","bytes32","uint256"]`
   produces exactly this). On-chain: `proposeMonth(YYYYMM, root, Σ amounts)`. `Σ amounts` must be
   ≤ `free()`; proposing a `total` smaller than the leaves' sum is allowed but late claimers will hit
   `ExceedsRemaining`.
4. **Three-day review.** Anyone can audit the published list against the root and check that every
   leaf's game id was listed before the proposal. If the list is wrong, `cancelMonth(month)` and
   `proposeMonth(month, …)` again with the same id. If the month id itself was mistyped, cancel it:
   `lastMonth` moves back and the right id can be proposed. A mistyped id that is **not** cancelled
   within three days is permanent and blocks every lower id, so check the id before the window ends.
   The id check is the only guard: `isValidMonth` does not compare the id with the calendar.
5. **Claims.** Publish the proofs; game developers or any relayer call `claim`.
6. **After 90 days.** Anyone calls `sweep(month)` so the remainder funds later months.

Choices made where the brief left a number open, all constants: `FIRST_YEAR = 2026`, year upper
bound `9999`, Sepolia `MOCK_SUPPLY = 1,000,000 OG`.

## Repository layout

```
foundry.toml, remappings.txt      solc 0.8.26, bytecode_hash = none, ffi off, no fs permissions
src/OGClubCreatorPool.sol         the contract
script/DeployCreatorPool.s.sol    mainnet (env OG_TOKEN, OWNER)
script/DeployCreatorPoolSepolia.s.sol  Sepolia (mock $OG + test games from JSON)
script/config/sepolia-games.example.json
test/*.t.sol                      unit, fuzz, invariant, integration, script tests
test/support/                     Merkle builder, MockOG, FeeOnTransferToken, reference OGClubFarmVault
lib/openzeppelin-contracts        OpenZeppelin Contracts v5.4.0, vendored as plain files
lib/forge-std                     forge-std v1.11.0, vendored as plain files
```

## Not a security audit

Tests passing is not an audit. The contract holds other people's $OG and should get an independent
adversarial review before release. Slither was not available on the build machine; the code avoids
its outright-reject detectors by construction (no `selfdestruct`, `transferFrom` only from
`msg.sender`, no initializers or upgrade paths, no Yul shifts, no `abi.encodePacked` of dynamic data).
