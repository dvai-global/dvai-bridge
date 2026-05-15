# Contributing to DVAI Bridge

Thank you for your interest in contributing to DVAI Bridge. This document
explains how to contribute code, documentation, bug reports, and feature
suggestions to the project.

We welcome contributions from individuals and organisations. To make the
contribution process work for both contributors and Deep Voice AI Limited as
the project owner, please follow the process described below.

## Before you contribute — the Contributor Licence Agreement

DVAI Bridge is **dual-licensed**:

- Free for personal, educational, academic-research, evaluation, and
  internal-only use under the **DVAI Bridge Community Licence v1.0**
  ("DVAI-BCL v1.0" — see [`LICENSE`](./LICENSE)).
- Commercially licensed for use in revenue-generating products. See
  [the licensing page](https://deepvoiceai.co/licensing) for commercial
  terms.

To support this dual-licensing model, **all contributors must sign the DVAI
Bridge Contributor Licence Agreement (CLA)** before any pull request can be
merged. The CLA grants Deep Voice AI Limited the licenses needed to
redistribute your contribution under both the Community Licence and the
Commercial Licence, and to support the automatic conversion of each Released
Version to Apache 2.0 three years after release. **You retain copyright in
your contribution.** The CLA does not transfer ownership.

There are two variants:

- **Individual CLA** — if you are contributing on your own behalf, and no
  employer has rights to your work.
- **Corporate CLA** — if you are contributing as an employee of a company
  that has rights to your work product. The company signs the Corporate CLA
  once, then adds employees to the schedule.

Read the full CLA at: **https://deepvoiceai.co/cla**

When you submit your first pull request, the **CLA Assistant** bot will
comment on the PR with a link to the CLA. Following the bot's instructions
to sign the CLA is a one-time step (unless the CLA is later updated). Once
signed, all your future contributions are covered automatically.

If you have questions about which CLA applies to your situation, contact us
at `info@deepvoiceai.co`. We'd rather have a quick conversation than have
you guess.

## How to contribute

### Bug reports

Bug reports are welcomed via [GitHub Issues](https://github.com/dvai-global/dvai-bridge/issues).
Before opening a new issue, please:

- Search existing issues to see if the bug has already been reported.
- Verify the bug against the latest released version.
- If you can reproduce the bug, include a minimal reproducible example.

A good bug report includes:

- The version of DVAI Bridge you are using.
- The host environment (operating system, framework, mobile platform
  version, etc.).
- The expected behaviour and the actual behaviour.
- Steps to reproduce, ideally with a minimal code example.
- Any relevant logs, error messages, or screenshots.

Our bug-report template in `.github/ISSUE_TEMPLATE/bug_report.yml` collects
this structured information automatically.

### Feature requests

Feature requests are welcomed via [GitHub Issues](https://github.com/dvai-global/dvai-bridge/issues/new/choose)
with the `feature request` label, or via
[GitHub Discussions](https://github.com/dvai-global/dvai-bridge/discussions)
for open-ended ideas.

Before opening a feature request, please:

- Search existing issues and discussions to see if the feature has already
  been proposed.
- Describe the use case the feature addresses — not just the feature itself.
- Indicate whether you would be willing to contribute the feature yourself
  (welcome but not required).

Deep Voice AI Limited makes all decisions about the DVAI Bridge product
roadmap. Feature requests are considered as input but not commitments.

### Pull requests

Code contributions are welcomed via GitHub Pull Requests. The workflow:

1. Fork the repository to your own GitHub account.
2. Create a feature branch from `main` with a descriptive name (e.g.
   `fix/streaming-error-503-retry-after-header` or
   `feature/openai-image-route`).
3. Make your changes following the code style guidelines below.
4. Add or update tests as appropriate. We strongly prefer pull requests that
   include test coverage for new behaviour.
5. Update documentation in the relevant files (README, API documentation,
   design documents, inline code comments) where the change affects
   user-facing behaviour or developer interfaces. Cross-SDK changes also
   need `docs/llms-full.txt` re-sync.
6. Open a pull request against `main` with a clear description of what the
   change does and why it is needed.
7. **Sign the CLA when prompted by the CLA Assistant bot.** The bot will
   comment on the PR with a link.
8. Respond to review feedback from the DVAI Bridge maintainers.

Pull requests that include tests, documentation, and a clear rationale are
easier and faster to review.

### Documentation contributions

Documentation contributions are particularly welcomed. Documentation may
include:

- README and getting-started guides.
- API reference documentation.
- Tutorial content and worked examples.
- Architecture and design documentation.
- Inline code comments improving readability.

Documentation contributions follow the same pull request workflow as code
contributions, **including the CLA requirement**.

## Code style

### General principles

- **Clarity over cleverness.** Code is read more often than it is written.
  Choose explicit and readable solutions over clever ones.
- **Match the existing style.** When in doubt, look at how nearby code is
  written and follow the same patterns.
- **Comment the "why", not the "what".** The code shows what is happening;
  comments should explain why.
- **Tests are part of the implementation.** Pull requests should include
  tests for new behaviour and updates to existing tests where behaviour
  changes.

### Language-specific style

DVAI Bridge is implemented across multiple languages. Each language has its
own style conventions, broadly following the canonical guides:

- **TypeScript / JavaScript:** ESLint configuration in the repository;
  conventions follow the standard TypeScript style guide.
- **Swift (iOS):** SwiftLint configuration in the repository; conventions
  follow the Swift API Design Guidelines.
- **Kotlin (Android):** Ktlint configuration in the repository; conventions
  follow the Kotlin coding conventions.
- **Rust (DVAI Hub):** rustfmt configuration in the repository; conventions
  follow the Rust API Guidelines.

CI runs lint checks on all pull requests; PRs that fail lint will be
flagged for correction.

### Commit messages

PR titles (which become squash-merge commit subjects) follow the
Conventional Commits format where practical:

```
<type>(<scope>): <subject>

<body>

<footer>
```

Types include `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`.
Scopes correspond to areas of the codebase (e.g. `ios`, `android`, `hub`,
`core`).

Example:

```
fix(android): correct Retry-After header parsing in error response

The 503 no_capable_device response previously emitted Retry-After as
an integer; corrected to comply with RFC 7231 which permits either
HTTP-date or seconds. Adopted seconds-only to align with the iOS
implementation.

Refs: #142
```

## Code of Conduct

DVAI Bridge follows the
[Contributor Covenant Code of Conduct, version 2.1](https://www.contributor-covenant.org/version/2/1/code_of_conduct/).
See [`CODE_OF_CONDUCT.md`](./CODE_OF_CONDUCT.md) for the project's adopted
version.

In short: be welcoming, be respectful, be constructive. Harassment,
discrimination, and aggressive behaviour are not tolerated.

Reports of unacceptable behaviour can be sent to `info@deepvoiceai.co` and
will be handled by Deep Voice AI Limited in confidence.

## Review and merging

Pull requests are reviewed by the DVAI Bridge maintainers (currently the
Deep Voice AI Limited engineering team). Reviews typically include:

- **Correctness review** — does the code do what the PR description says?
- **Style review** — does the code follow the project's conventions?
- **Test review** — are the tests appropriate and sufficient?
- **Design review** — does the change fit the project's architecture and
  direction?
- **Structure Review** - does the code create dependencies which impact performance or create issues elsewhere in the code base?

Reviewers may request changes, suggest alternative approaches, or approve
the PR for merging. Merging is at the discretion of the maintainers; not
every PR will be merged, and we may decline contributions that do not fit
the project's direction. We try to communicate clearly when we decline a PR
and will, where possible, explain the reasoning.

After approval, the **CLA Assistant** bot must confirm that the contributor
has signed the CLA. Once both review approval and CLA signature are in
place, the PR is squash-merged into `main`.

## Acknowledgement of contributors

Contributors whose pull requests are merged are acknowledged in the
repository's contributor list (maintained by GitHub automatically). For
significant contributions, additional acknowledgement may appear in release
notes, the README, or the project's website.

We are grateful to everyone who contributes to DVAI Bridge.

## Getting help

If you have questions about contributing that are not answered above:

- **[GitHub Discussions](https://github.com/dvai-global/dvai-bridge/discussions)**
  for open-ended questions about the project.
- **Email** `info@deepvoiceai.co` for any other enquiries.

Thank you for contributing to DVAI Bridge.

---

Last updated: 15 May 2026.
Deep Voice AI Limited, registered in England and Wales, company number
16743132.
