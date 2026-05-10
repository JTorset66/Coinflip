# Code Signing Policy

Policy for building, reviewing, and signing Coinflip release binaries.

Free code signing provided by [SignPath.io](https://about.signpath.io), certificate by [SignPath Foundation](https://signpath.org).

Status:

- Preparing for a SignPath Foundation application.
- Until that application is approved and integrated, published binaries may be unsigned or signed through a separate trusted Windows code-signing setup controlled by the project maintainer.

## Project roles

- Committer and reviewer: John Torset
- Approver for release signing: John Torset

If the project team expands, update this policy to reflect the active maintainers and approvers.

## Source of truth

- Primary repository: <https://github.com/JTorset66/Coinflip>
- Default branch: `main`

Only binaries built from this repository and maintained by the project may be signed under this policy.

## Release build policy

- Release artifacts must be built from source in this repository.
- Prefer automated workflow builds on a controlled Windows runner with PureBasic and Inno Setup installed.
- Release tags use the format `v*`.
- The produced executable and installer names must match the project version embedded in the source and build output.
- Build scripts, installer scripts, and workflow definitions are part of the trusted source and must be reviewed with the same care as application code.

## Signing policy

- Only project-owned binaries may be signed.
- Third-party upstream executables and DLLs must not be re-signed as if they were project binaries.
- If signing is enabled for a release build, the signed artifacts must come from the automated release workflow or an equivalent controlled maintainer-run process.
- The installer must contain only project release files and documented dependencies.
- The installer must include the user README, license, and third-party notices shipped with the release.
- Every signing event must correspond to a release the project intends to publish.

## Privacy policy

Coinflip does not transfer information to other networked systems unless specifically requested by the user or the person installing or operating it.

## User safety

- The project must not include malware, potentially unwanted software, or features intended to bypass platform security controls.
- System changes must be transparent to the user.
- The installer must provide clear uninstall support.
- The installer must not create startup entries, background tray behavior, or Start Menu shortcuts unless the documentation and release checklist are updated first.

## Repository security expectations

- Maintainers involved in releases use multi-factor authentication for GitHub and any signing platform.
- Release approvals apply only to reviewed code that matches the intended tagged source revision.
