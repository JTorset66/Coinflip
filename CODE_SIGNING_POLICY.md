# Code Signing Policy

This document describes how release binaries for Coinflip are built, reviewed, and signed.

Free code signing provided by [SignPath.io](https://about.signpath.io), certificate by [SignPath Foundation](https://signpath.org).

Current status:

- This repository is preparing for a SignPath Foundation application.
- Until that application is approved and integrated, published binaries may be unsigned or signed through a separate trusted Windows code-signing setup controlled by the project maintainer.

## Project roles

- Committer and reviewer: John Torset
- Approver for release signing: John Torset

If the project team expands, this policy will be updated to reflect the active maintainers and approvers.

## Source of truth

- Primary repository: <https://github.com/JTorset66/Coinflip>
- Default branch: `main`

Only binaries built from this repository and maintained by this project may be signed under this policy.

## Release build policy

- Release artifacts must be built from source in this repository.
- Builds should be produced by an automated workflow on a controlled Windows runner with PureBasic installed.
- Release tags should use the format `v*`.
- The produced executable name must match the project version embedded in the source and build output.
- Build scripts and workflow definitions are part of the trusted source and must be reviewed with the same care as application code.

## Signing policy

- Only project-owned binaries may be signed.
- Third-party upstream executables and DLLs must not be re-signed as if they were project binaries.
- If signing is enabled for a release build, the signed artifact must come from the automated release workflow or an equivalent controlled maintainer-run process.
- Every signing event must correspond to a release the project intends to publish.

## Privacy policy

This program will not transfer any information to other networked systems unless specifically requested by the user or the person installing or operating it.

The application can optionally perform a local self-test against `onnxruntime.dll` when that DLL is present on the same system. This behavior is local to the machine and does not require network access.

## User safety

- The project must not include malware, potentially unwanted software, or features intended to bypass platform security controls.
- System changes must be transparent to the user.
- If the project later adds an installer, it must also provide clear uninstall instructions or an uninstall mechanism.

## Repository security expectations

- Maintainers involved in releases should use multi-factor authentication for GitHub and any signing platform.
- Release approvals should only be given for reviewed code that matches the intended tagged source revision.

