# SignPath Foundation Application Draft

This document collects the information needed to apply for a free SignPath.io subscription through SignPath Foundation.

## Project summary

- Project name: Coinflip
- Project handle: coinflip
- Repository: <https://github.com/JTorset66/Coinflip>
- Latest public release: <https://github.com/JTorset66/Coinflip/releases/tag/v1.10>
- License: GPL-3.0
- Maintainer: John Torset
- Primary platform: Windows x64
- Project description: PureBasic desktop application for large-scale fair-coin simulation, deviation analysis, and high-throughput benchmarking

## Why this project fits the program

- The repository is public.
- The project uses an OSI-approved open-source license.
- The published release artifact is built from the repository source.
- The repository includes a public code signing policy and privacy statement.
- The application does not include network telemetry or data transfer unless explicitly requested by the user or operator.
- The project is a user-facing Windows desktop application where trusted code signing materially improves install and run experience.

## Current public links

- Repository home: <https://github.com/JTorset66/Coinflip>
- Release page: <https://github.com/JTorset66/Coinflip/releases/tag/v1.10>
- Code signing policy: <https://github.com/JTorset66/Coinflip/blob/main/CODE_SIGNING_POLICY.md>
- Release checklist: <https://github.com/JTorset66/Coinflip/blob/main/RELEASE_CHECKLIST.md>

## Compliance notes against SignPath Foundation terms

### License and source availability

- All repository content intended for release is open source under GPL-3.0.
- There is no commercial dual-licensing statement in the repository.
- The project does not intentionally bundle proprietary maintainer-owned components.

### Released and documented

- Version `v1.10` is publicly released on GitHub with binaries and checksum files.
- The repository README describes the software, build requirements, runtime notes, and usage.

### Privacy and user safety

- The project states: "This program does not transfer information to other networked systems unless specifically requested by the user or the person installing or operating it."
- The optional ONNX Runtime self-test is local to the machine and does not require network access.
- The project is not a hacking tool and does not include features intended to bypass platform security controls.

### Roles and approvals

- Committer and reviewer: John Torset
- Release signing approver: John Torset

### Build and signing readiness

- The repository includes a self-hosted Windows GitHub Actions workflow for release builds.
- The release process is documented in `RELEASE_CHECKLIST.md`.
- The repository includes a code signing policy that uses the required SignPath Foundation wording.

## Honest caveats to mention if asked

- The project is newly public and currently has limited external reputation.
- The current release binary is unsigned because SignPath onboarding is not yet complete.
- The self-hosted Windows build workflow is present in the repository, but actual SignPath integration still depends on onboarding and runner setup.

## Suggested form/email answers

### Short project description

Coinflip is a Windows x64 PureBasic desktop application for large-scale fair-coin simulation and deviation analysis. It supports exact bit-level simulation, multiple binomial sampling paths, multithreaded execution, live plotting, and optional binary output for later analysis.

### Why code signing is needed

Coinflip is distributed as a Windows desktop executable. Trusted code signing would help users verify that published binaries come from the public repository and would reduce Windows trust friction for open-source releases.

### Why SignPath should consider it

The project is fully open source, publicly released, documented, and already includes a public code signing policy, privacy statement, release checklist, and source-controlled release workflow. The project is intended to distribute Windows binaries directly to end users, making repository-to-binary verification especially valuable.

