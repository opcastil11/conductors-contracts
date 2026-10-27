# Security Policy

## Status

These contracts are **pre-audit** and deployed only on testnets. They have been through an
internal review (see [README](README.md#security-properties)) and are covered by unit,
end-to-end, fuzz and invariant tests, but they have not been audited by a third party.

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Report privately through GitHub's
[private vulnerability reporting](https://github.com/opcastil11/conductors-contracts/security/advisories/new).
Include the affected contract, a description of the issue, and a proof of concept or failing
test if you have one.

We aim to acknowledge reports within 72 hours and to keep you updated until the issue is
resolved. Good-faith research is welcome; please avoid any testing that affects other users'
funds or degrades public infrastructure.

## Scope

| In scope | Out of scope |
|---|---|
| Everything under `contracts/` | `contracts/mocks/` (test-only) |
| Deployment scripts in `scripts/` | Third-party dependencies (OpenZeppelin, forge-std) |
| | The Conductors web app and API (separate private repo) |
