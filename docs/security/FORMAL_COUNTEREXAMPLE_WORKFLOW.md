# Formal Counterexample Workflow

Use this workflow when the governance invariant suite fails locally or in CI.

## Trigger

- `npm run formal:governance` fails
- the `Formal Governance Verification` GitHub Actions job fails
- the exported artifact manifest identifies a new failed invariant

## Triage Steps

1. Identify the failed invariant name from the test output or CI logs.
2. Reproduce locally with `npm run formal:governance`.
3. Determine whether the failure is:
   - a real contract bug
   - a stale or incomplete spec
   - a fixture/setup error
4. If it is a real bug, open or link the remediation issue before changing the spec.
5. If it is a spec gap, update the invariant and add a regression test proving the intended behavior.
6. Regenerate the artifact manifest with `npm run formal:artifacts`.

## Required Evidence On Every Failure

- failing invariant name
- failing commit SHA
- reproduction command
- root-cause classification: bug, spec gap, or fixture error
- linked remediation issue or PR

## Exit Criteria

- invariant passes locally
- CI formal verification job passes
- regression coverage for the counterexample is committed
- the issue or PR thread records the failure and the fix
