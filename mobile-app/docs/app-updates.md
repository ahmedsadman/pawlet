# App updates

Copies installed from Google Play find out about new versions themselves and update through Play
without leaving the app. Copies installed any other way (debug builds, `adb`, a downloaded APK)
never check: Play only serves updates to installs it delivered.

## What the user sees

1. **The offer.** When Play has a newer version, a bottom sheet slides up: "A new version is
   ready", with **Update** and **Not now**.
2. **Play's confirmation.** Tapping **Update** opens Play's own small dialog. That second tap is
   part of Play's flexible update flow and cannot be skipped.
3. **The download.** Play downloads in the background while the app stays usable. Play's
   notification shows progress; the app shows nothing while it runs.
4. **The restart.** When the download finishes, a snackbar says "Update downloaded" with a
   **Restart** action. It stays until tapped. Restarting hands over to Play, which installs the
   update and reopens the app. If the user ignores it, the snackbar comes back on the next resume
   or launch.

## When it checks

- On launch, after the first-run flow (SMS disclosure, inbox import) is done, and on every return
  to the foreground.
- Only once the app is unlocked, so the sheet never covers the lock screen.
- **Not now**, dismissing the sheet, and declining Play's dialog all snooze the automatic offer.
  The snooze is not tied to one version.
- **Settings → Check for updates** (Play installs only) ignores the snooze and always says what it
  found: up to date, couldn't reach Google Play, already downloading, or the offer itself.

| Constant (snapshot) | Value | Source |
|---|---|---|
| Snooze after "Not now" | 3 days | `lib/services/app_update_service.dart` (`AppUpdateService.snoozeFor`) |

## Where it lives

- `lib/services/app_update_service.dart`: asks Play and reduces the answer to a status; holds the
  snooze rule.
- `lib/ui/app_update_flow.dart`: the sheet, the snackbar and the order of steps.
- `lib/app.dart` (`RootShell`): when the automatic check runs.
- The snooze is stored in `lib/data/settings_repository.dart` and is not part of Backup & Restore.

## Testing an update for real

In-app updates only work for a copy Play installed, so this cannot be tried with a debug build.

1. Install the app from the Play internal testing track.
2. Publish a build with a higher version code to the same track.
3. Open the app. Play can take a while to report a new version; opening the app's page in the Play
   Store app usually refreshes it.
