# Proof-of-Sequestration capture packet (Issue #143)

## Outcome

This issue is a **design capture only** and should not be implemented in this PR.
The first concrete decision is to define a constrained v1 scope as a decision packet
that can be converted into implementation PRs later when oracle and DAO economics seams are
ready.

## Context

- Issue: capture workstream item to reward permanent carbon sequestration (“work earner” model).
- Constraint: there is no existing production-grade permanent-lock oracle or durable verification
runtime in this repo for v1, so implementation would be speculative.
- Related context: this idea currently sits under the DAO/autonomy epic (#134) and links to the
oracle workflow from the computational oracle story (#140).

## Decision packet: What PoS *means* in v1

1. **Economic meaning**
   - Reward only for projects represented by oracle-attested permanence, not for claimed reductions.
   - Initial payout is for a verified, irreversible sequestration claim after a permanence window.
   - Credits are treated as payout rights; token issuance or conversion mechanics are deferred.

2. **Actor model**
   - `work earner` = on-chain participant with stake/identity tied to one or more sequestration
     projects.
   - `verifier set` = trusted oracle federation with auditable key management and role-based
     invocation.
   - `allocator` = DAO/treasury pathway through existing governance/timelock controls.

3. **Oracle-verifiable condition (minimum viable semantics)**
   - Verifier submits a structured attestation keyed by project + project lifecycle phase.
   - Payout eligibility requires:
     - minimum confidence threshold,
     - verifier quorum policy,
     - finalization confirmation event.
   - Off-chain evidence payload must include immutable project identifier, location scope,
     sequestration method, mass/volume estimate, permanence assumptions, and expiry horizon.

4. **Permanence and reversal**
   - Permanence is not immediate. A staged model is required:
     - `staged` → `provisional` → `final` eligibility, where finalization is time-gated and
       oracle-anchored.
   - Any later reversal event requires:
     - oracle-asserted reversal attestation,
     - governance-controlled clawback/rollback path,
     - optional penalty accounting for oracle provider misbehavior.
   - No silent continuation when permanence expires without revalidation.

5. **Governance and safety boundary (hard requirements)**
   - Treasury/cap allocations are DAO-governance controlled.
   - Emergency pause and role revocation must exist on any PoS payout path.
   - Reversal and compensation logic must fail closed on missing/expired oracle confidence.

6. **Cross-contract seam policy**
   - Keep project registry, payout calculations, and treasury transfer logic separable.
   - Do not couple sequestration claims directly into existing carbon credit offset flows
     (different semantics: permanence vs offset accounting).
   - Reuse any stable oracle resolution patterns only after an explicit v1 seam exists.

## Out-of-scope for this packet

- New smart contracts or storage migrations.
- New oracle connectors.
- Token model/tokenomics changes in this PR.
- New payout implementation.

## Concrete next-step packet actions

- Implement the above as a separate ADR when the oracle seam is approved by issue owners.
- Open an implementation issue for v1 only when at least:
  - a live oracle-sealed permanence payload contract exists,
  - DAO/treasury parameter schema is finalized,
  - reversal/clawback policy has one explicit actor path and a timelock model.
- Keep this PR as the decision record and do not stack implementation work into it.
