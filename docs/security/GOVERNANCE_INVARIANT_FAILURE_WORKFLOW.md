# Governance invariant test failures

Use this workflow when the governance invariant tests fail locally or in CI. They are Hardhat/Chai
tests of named invariants against `contracts/governance/FormalVerificationSpecs.sol` (a test
harness); no theorem prover or model checker is involved, so a pass is test evidence, not a proof.

## Trigger

- `npm run governance:invariants` fails
- the `Governance invariant tests` GitHub Actions job fails
- the exported artifact manifest identifies a new failed invariant

## Triage Steps

1. Identify the failed invariant name from the test output or CI logs.
2. Reproduce locally with `npm run governance:invariants`.
3. Determine whether the failure is:
   - a real contract bug
   - a stale or incomplete spec
   - a fixture/setup error
4. If it is a real bug, open or link the remediation issue before changing the spec.
5. If it is a spec gap, update the invariant and add a regression test proving the intended behavior.
6. Regenerate the artifact manifest with `npm run governance:invariants:artifacts`.

## Required Evidence On Every Failure

- failing invariant name
- failing commit SHA
- reproduction command
- root-cause classification: bug, spec gap, or fixture error
- linked remediation issue or PR

## Exit Criteria

- invariant passes locally
- the CI governance invariant job passes
- regression coverage for the counterexample is committed
- the issue or PR thread records the failure and the fix
