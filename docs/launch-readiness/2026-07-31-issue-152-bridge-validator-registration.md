# Launch ops: register bridge validators before enabling high-security NFT transfers (#152)

**Ops action, before opening the bridge to high-value traffic:**

Register at least the profile-required number of active validators in
`CrossChainBridgeSecurityHardening` via `registerEnhancedValidator(validator,
stake, nodeId, endpoint)` (stake is sent as `msg.value`). The value-based
profiles require 3 (LOW) / 4 (MEDIUM) / 5 (HIGH) / 6 (ULTRA_HIGH) validators.

**On-chain behavior backing this checklist item** (as of the #152 fix):

- A transfer whose security level resolves to **HIGH or above** reverts with
  `SecureBridge: No active validators registered` while the registry is empty.
  Fresh deployments therefore fail closed instead of silently skipping
  validator assignment.
- LOW/MEDIUM transfers still initiate against an empty registry (pre-existing
  behavior, deliberately unchanged — see `[P0-A]` in
  `test/launch-blockers.test.js`).
- A non-empty registry whose validators are all inactive reverts for every
  tier (pre-existing `require(activeCount > 0)`).

**Known residual, tracked separately:** assigned validators are recorded but
not yet consulted by any approval/execution path (`transferValidators` is
write-only). Registration is necessary, not sufficient — see the follow-up
issue filed from the #152 fix PR.
