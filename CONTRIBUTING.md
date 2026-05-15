# Contributing to dvai-bridge

Thanks for your interest in contributing. This is a commercial repo — see
[LICENSE](./LICENSE) for the full terms — but external PRs are welcome
under the contribution model below.

## Quick start

```bash
# Clone + install (pnpm monorepo for the JS family)
git clone https://github.com/dvai-global/dvai-bridge.git
cd dvai-bridge
pnpm install

# Build the JS family + run JS tests
pnpm build
pnpm test

# Build the platforms your machine can build
bash scripts/build-all.sh
```

`build-all.sh` auto-detects host (Mac vs. Windows vs. Linux) and runs
only the slices that work there. iOS + Mac Catalyst require a Mac;
.NET / Web / Android run on any host.

## PR flow

1. **Open or pick up an issue.** Larger changes (new SDK, new backend,
   API shape changes) need a design discussion first — open an issue
   describing the proposal before sending a PR. Smaller fixes (bug
   reports, doc corrections, build-script tweaks) can go straight to PR.
2. **Branch from main.** No long-lived feature branches; small,
   focused PRs land faster.
3. **Build + test the slice you touched** using the relevant
   `scripts/build-<slice>.sh` script. CI re-runs the full matrix on
   open + push, but a local pass saves a round-trip.
4. **Open the PR.** Link the issue. The PR description should explain
   *why*, not just *what* — the diff already shows what changed.
5. **Address review feedback** as additional commits on the same
   branch. Maintainers squash-merge; intermediate commits don't end
   up on main.

## Per-platform contributor docs

The cross-cutting build + test loop is in `scripts/build-*.sh`. Per-SDK
mechanics, common breakage modes, and "I just touched this for the
first time" notes live under `docs/development/`:

| Slice         | Page                                                                                              |
| ------------- | ------------------------------------------------------------------------------------------------- |
| iOS native    | [contributing-ios.md](./docs/development/contributing-ios.md)                                     |
| Android native| [contributing-android.md](./docs/development/contributing-android.md)                             |
| React Native  | [contributing-react-native.md](./docs/development/contributing-react-native.md)                   |
| Flutter       | [contributing-flutter.md](./docs/development/contributing-flutter.md)                             |
| .NET          | [contributing-dotnet.md](./docs/development/contributing-dotnet.md)                               |
| Tests         | [testing.md](./docs/development/testing.md)                                                       |
| Mac SSH builds| [mac-remote-builds.md](./docs/development/mac-remote-builds.md)                                   |
| Backend internals | [handler-parity.md](./docs/development/handler-parity.md), [litert-lm-migration-notes.md](./docs/development/litert-lm-migration-notes.md) |

## Commit message convention

Conventional Commits with a phase prefix where the work is part of a
numbered phase. Examples lifted from `git log`:

```
feat(phase3g-tasks-14-25): desktop + Mac Catalyst + ONNX + ML.NET expansion
docs(phase3g): revise spec + plan to add desktop, Mac Catalyst, ONNX, ML.NET
chore(release): bump versions to 2.4.0 + tag v2.4.0 (Phase 3G)
docs(research): MLC LLM backend feasibility study
fix(android): correct LiteRT delegate selection on QNN-capable devices
```

Types in active use: `feat`, `fix`, `docs`, `chore`, `build`, `ci`,
`test`, `refactor`. Scope is the phase + task name where applicable
(`phase3g-tasks-14-25`), or the slice (`android`, `ios`, `flutter`,
`dotnet`, `react-native`, `core`).

The body explains *why*; a subject line under 80 chars is preferred.
Don't include `Co-Authored-By:` trailers (project convention).

## License + copyright

dvai-bridge is dual-licensed — free for development on `localhost` /
`127.0.0.1`, commercial license required for production use. By
submitting a PR you agree that your contribution is licensed under the
same terms as the rest of the repo (see [LICENSE](./LICENSE)) and that
copyright in the contribution is assigned to Deep Voice AI Limited.

If you can't make that assignment for legal reasons (corporate IP
agreements, etc.), please reach out at `info@deepvoiceai.co` before
opening the PR so we can sort out a CLA-equivalent path.

## Code of conduct

Be respectful in issues, PRs, and discussions. We won't gatekeep on
opinion, and we don't have a separate Code of Conduct file at this
project size — but reports of harassment will be handled directly by
the maintainers (`info@deepvoiceai.co`) and grounds for permanent
removal from the project.

## Questions?

- **Build / dev setup not working?** Open an issue with the output of
  the failing `scripts/build-<slice>.sh` script.
- **Architecture / design question?** Read [RESEARCH.md](./RESEARCH.md)
  first; if the answer isn't there, open an issue with `[design]` in
  the title.
- **Commercial licensing?** Email `info@deepvoiceai.co`.
