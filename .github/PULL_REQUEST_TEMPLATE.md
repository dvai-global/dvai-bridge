## Summary

<!-- One or two sentences. What does this PR change and why. -->

## Type of change

- [ ] Bug fix (non-breaking change that fixes an issue)
- [ ] New feature (non-breaking change that adds functionality)
- [ ] Breaking change (fix / feature that would cause existing
      consumers to fail without a code change on their side)
- [ ] Documentation only
- [ ] Refactor (no functional change)
- [ ] Test / CI infrastructure

## Motivation

<!-- The problem this PR solves. Link the GitHub issue if applicable:
Fixes #NNN / Refs #NNN. -->

## Testing

<!-- How did you verify this works? Be specific about platforms.

  - Tests added / updated: …
  - Manual verification: ran the X example on Y platform, checked Z.
  - CI: which workflows ran and passed in your fork / branch.

Tests are required when:
  - Behaviour changes (new test + assertion).
  - Bug fixes (regression test that fails on the old code).
  - License / security paths (must add unit tests).
-->

## Checklist

- [ ] PR title follows `<module>: <imperative summary>` (e.g.
      `core: fix license JWT replay edge case`). Will be the squash
      commit subject — keep it under 70 chars.
- [ ] `CHANGELOG.md` updated under `## [Unreleased]` if this is
      consumer-visible.
- [ ] Docs updated under `docs/` if behaviour, API, or setup
      instructions changed. Cross-SDK changes also need
      `docs/llms-full.txt` re-sync.
- [ ] `pnpm test` passes locally (the JS unit-test suite).
- [ ] No new lint warnings.
- [ ] No new secrets, credentials, or large binaries committed.
- [ ] If breaking: a `docs/migration/vX-to-vY.md` entry exists.

## Breaking change notes

<!-- If this is a breaking change, describe:
  - What breaks
  - How consumers should migrate
  - Whether an automated codemod is feasible

Leave blank for non-breaking changes. -->
