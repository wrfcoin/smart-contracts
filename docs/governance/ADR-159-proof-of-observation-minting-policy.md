# ADR-159: Proof-of-Observation minting remains disabled pending an approved policy

**Status:** Accepted for the current testnet cut

**Issue:** Refs #159

## Context

Proof-of-Observation would turn a hardware-signed environmental frame into a
token mint. That changes token supply and must not be inferred from a test
fixture, a caller-selected work factor, or a self-asserted station identity.
The required W3 frame and ATECC608A/P-256 verification contract are not yet
available in this repository (#158).

## Decision

No smart-contract Proof-of-Observation mint path will be deployed or enabled
until governance approves the policy below and #158 provides the canonical
frame-verification seam. Existing reward paths are unchanged.

The eventual policy MUST specify, as immutable input to the mint decision:

1. The versioned W3 frame digest and domain separation (chain, contract,
   network, and schema version).
2. The registered hardware root, active key version, and P-256 verification
   method; an arbitrary Ethereum key is not a hardware-root substitute.
3. A replay identity that survives offline buffering: registered node identity
   plus a monotonic sequence or signed frame identifier, with consumed-frame
   storage scoped to the canonical digest.
4. The payout schedule, per-node and global emission caps, and the authority
   allowed to change them.
5. The treatment of late/offline frames, clock bounds, duplicate frames, and
   key rotation/revocation.
6. The independent plausibility/quarantine result required before a frame can
   mint, including what happens when that result is unavailable.

## Consequences

- A later implementation must fail closed if any required proof, replay state,
  registry state, policy parameter, or plausibility attestation is absent.
- Tests must show a deliberately replayed buffered frame and an unregistered
  signer both revert at the mint seam; a happy-path mint is not sufficient.
- This ADR does not choose a reward curve or authorize a token-supply change.
  Those require a follow-up governance decision with named values and a
  supply-impact review.
