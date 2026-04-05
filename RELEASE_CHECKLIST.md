# Release Checklist

Use this checklist for public Coinflip releases.

## Before tagging

- Confirm the intended version number in `Coinflip_V1.10.pb`.
- Review `README.md` for any release notes, usage notes, or dependency changes.
- Confirm the project still matches the statements in `CODE_SIGNING_POLICY.md`.
- Build locally with:

```powershell
.\build-purebasic.ps1
```

- Verify the output exists in `build\`.
- If signing is available, sign and verify the executable before release.
- Test-launch the built executable on Windows.
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
- Verify the release assets include the `.exe` and `.sha256` files.
- Add or review release notes on GitHub.

## After release

- Download the published asset once and verify it runs.
- If signed, verify the Windows signature and timestamp on the published binary.
- Record any release issues before starting the next version.

