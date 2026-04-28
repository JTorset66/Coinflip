# Release Checklist

Use this checklist for public Coinflip releases.

## Before tagging

- Confirm the intended version number in `Coinflip_V1.10.pb`.
- Confirm the intended version number and artifact names in `coinflip.iss`.
- Review `README.md` for any release notes, usage notes, or dependency changes.
- Confirm `THIRD_PARTY_NOTICES.md` is included with the installer and still matches the application icon.
- Confirm the project still matches the statements in `CODE_SIGNING_POLICY.md`.
- Build locally with:

```powershell
.\build-purebasic.ps1
.\build-installer.ps1
```

- Verify the executable and installer exist in `build\`.
- If signing is available, sign and verify the executable and installer before release.
- Test-launch the built executable on Windows.
- Test-install the built installer on Windows.
- Confirm the installed maintenance entry offers Repair install and Uninstall.
- Confirm GitHub MFA is enabled for the maintainer account.

## Git preparation

- Review pending changes:

```powershell
git status
git diff --stat
```

- Commit the release-ready state.
- Create an annotated tag using the release version.

## GitHub release

- Push `main`.
- Push the version tag.
- Confirm the GitHub Actions workflow completes successfully on the self-hosted Windows runner.
- Verify the release assets include the executable, installer, and `.sha256` files.
- Add or review release notes on GitHub.

## After release

- Download the published assets once and verify the executable runs.
- Install from the downloaded installer.
- If signed, verify the Windows signature and timestamp on the published binaries.
- Record any release issues before starting the next version.
