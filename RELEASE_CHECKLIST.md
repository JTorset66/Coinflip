# Release Checklist

Checklist for public Coinflip releases.

## Before tagging

- Confirm the intended version number in `Coinflip_V1.12.pb`.
- Confirm the intended version number and artifact names in `coinflip.iss`.
- Confirm the full stamped release version from build metadata.
- Use the full `v1.12.YYMM.minute-of-month` style version for public release tags and generated artifact filenames.
- Avoid short `v1.12` artifact names.
- Review `README.md` for any release notes, usage notes, or dependency changes.
- Review the release notes file for the intended GitHub release tag.
- Review `INSTALLER_README.md` for user-facing app functionality and usage changes.
- Confirm the main window follows Windows display scaling, including a high-DPI check at 200%.
- Confirm startup opens directly maximized to the current Windows monitor work area, without a visible normal-window step or off-center placement.
- Confirm no horizontal or vertical scrollbars are visible at startup.
- Confirm the maximum window is the available Windows work-area maximum at each tested Windows DPI and View scale.
- Confirm View scale changes keep the current normal-window size and position.
- Confirm the fixed 9/8 UI boost makes 200% display scaling render close to a 225% control/text size.
- Confirm fonts, text boxes, buttons, columns, and plot controls stay at the fixed DPI-aware opening size when the window is resized.
- Confirm extra maximized space goes to the graph, run log, and status areas instead of enlarging controls.
- Confirm the graph, right-side controls, live status row, and progress bar fit in the visible window.
- Confirm numeric input boxes update related totals/settings when Enter is pressed and when focus leaves the field.
- Confirm window resizing, helper text redraw, log appends, progress redraw, live-status updates, and plot redraw do not visibly flicker.
- Confirm the progress bar percentage is white text with a black outline.
- Confirm run log entries are compact, planned setup and final results are not duplicated, throughput is shown as `cf/ms`, and total-cf lines include named text summaries.
- Confirm the installer includes `INSTALLER_README.md` as installed `README.txt`.
- Confirm the installer includes `USER_MANUAL.txt` as installed `USER_MANUAL.txt`.
- Confirm the installer includes `THIRD_PARTY_NOTICES.md` as installed `THIRD_PARTY_NOTICES.txt` and still matches the application icon.
- Confirm the installer includes `LICENSE` as installed `LICENSE.txt`.
- Confirm the installer creates a desktop shortcut and does not create Start Menu shortcuts.
- Confirm the project still matches the statements in `CODE_SIGNING_POLICY.md`.
- Build locally with:

```powershell
.\build-purebasic.ps1
.\build-installer.ps1
```

- Verify the executable and installer exist in `build\`.
- Confirm executable and installer filenames include the full stamped version.
- Example: `Coinflip_V1.12.2605.01042.exe` and `Coinflip_V1.12.2605.01042_Setup.exe`.
- If signing is available, sign and verify the executable and installer before release.
- Test-launch the built executable on Windows.
- Test-install the built installer on Windows.
- Confirm the installer "Read Included Files" page opens the README, user manual, license, and third-party notices as `.txt` files.
- Confirm the installed desktop shortcut launches Coinflip.
- Confirm no Coinflip Start Menu shortcut is created.
- Confirm the installed maintenance entry offers Repair install and Uninstall.
- Confirm GitHub MFA is enabled for the maintainer account.

## Git preparation

- Review pending changes:

```powershell
git status
git diff --stat
```

- Commit the release-ready state.
- Create an annotated tag using the full stamped release version, for example `v1.12.2605.01042`.

## GitHub release

- Push `main`.
- Push the version tag.
- Confirm the GitHub Actions workflow completes successfully on the self-hosted Windows runner.
- Verify the release assets include the executable, installer, and `.sha256` files.
- Add or review release notes on GitHub, using the full stamped version in the release title and notes.

## After release

- Download the published assets once and verify the executable runs.
- Install from the downloaded installer.
- If signed, verify the Windows signature and timestamp on the published binaries.
- Record any release issues before starting the next version.
