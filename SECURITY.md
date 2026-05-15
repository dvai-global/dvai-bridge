# Security Policy

DVAI-Bridge is a multi-platform local-AI SDK shipping under BSL 1.1
with commercial enforcement. Vulnerabilities in the SDK can affect
downstream applications running in production, so we take reports
seriously and respond on a predictable timeline.

## Supported Versions

Only the latest minor release of the current major version receives
security updates. Older minors / older majors are end-of-life — the
upgrade path is the migration guide for each major.

| Version | Supported          |
| ------- | ------------------ |
| v4.x    | :white_check_mark: |
| < v4.0  | :x:                |

When v4.1 ships, v4.0 stops receiving fixes; we don't backport across
minors. If you need long-term support on an older minor,
[open a discussion](https://github.com/dvai-global/dvai-bridge/discussions)
about commercial support.

## Reporting a Vulnerability

**Do not file public issues for security reports.** Use one of:

1. **GitHub Security Advisory (preferred)** — open
   [Security → Report a vulnerability](https://github.com/dvai-global/dvai-bridge/security/advisories/new).
   This routes the report privately to the maintainers and creates a
   tracked advisory thread.
2. **Email** — `info@deepvoiceai.co` with "DVAI-Bridge security"
   in the subject so it routes correctly.

Encrypted email is welcome but not required — reach out before
sending encrypted payloads so we can exchange keys.

### What to include

- A clear description of the vulnerability.
- A minimal reproduction — code snippet, test app, or step-by-step
  instructions. We'll need to validate the issue before scoping a
  fix.
- Affected SDKs / versions / platforms.
- Impact assessment in your own words (RCE? Cred theft? DoS? Trust
  bypass? Cross-tenant data leak?).
- Whether you've already disclosed to anyone else.

### What to expect from us

| Step | Target |
| --- | --- |
| Acknowledgement that the report was received | within 3 business days |
| Initial triage decision (in-scope, severity tier) | within 7 business days |
| Patch landed in a supported release (low / medium / high severity) | within 90 / 60 / 30 days respectively |
| Public advisory + CVE if applicable | coordinated with reporter |

We do not currently run a paid bug-bounty program. Responsible
reports are credited in the advisory and `CHANGELOG.md` unless the
reporter requests anonymity.

## Scope

In-scope (we want reports on these):

- The TypeScript core (`packages/dvai-bridge-core/`).
- The license validator on any SDK (`@dvai-bridge/core/license`,
  Swift `LicenseValidator`, Kotlin `LicenseValidator`,
  `DVAIBridge.License`, Dart `LicenseValidator`).
- The embedded HTTP server / OpenAI shim.
- Distributed-inference offload + rendezvous code.
- Native SDKs: `@dvai-bridge/ios`, `@dvai-bridge/android`,
  `@dvai-bridge/react-native`, `dvai_bridge` (Flutter),
  `DVAIBridge` (NuGet family), `@dvai-bridge/capacitor*`.
- DVAI Hub desktop app (`hub/`).

Out of scope:

- **Third-party backends.** Vulnerabilities in upstream `llama.cpp`,
  MediaPipe, MLX, Transformers.js, WebLLM, LiteRT, ONNX Runtime,
  or ML.NET should be reported to those projects directly. We'll
  bump the dependency once upstream ships a fix.
- **Example apps** under `examples/` — they're demonstrations, not
  production code.
- **Documentation typos** — open a regular issue or PR.
- **Resource-exhaustion DoS that requires arbitrary CPU / memory.**
  Local inference is inherently resource-intensive; "loading a 70B
  model OOMs my phone" is not a vulnerability.
- **Issues only reproducible against forks or custom builds.**

If you're unsure whether something is in scope, send the report
anyway — we'd rather decline a few than miss something real.

## Disclosure

We follow coordinated disclosure. Default embargo is 90 days from
when we acknowledge the report, extendable by mutual agreement.
Public disclosure happens via:

- A GitHub Security Advisory on this repo (assigns a CVE when the
  issue warrants one).
- An entry in `CHANGELOG.md` under a `### Security` heading for the
  release that contains the fix.
- A `dvai-global/dvai-bridge` Discussions thread linking to both.

If a fix lands in a private branch ahead of the advisory, the public
commit message uses a generic description until the embargo lifts.
