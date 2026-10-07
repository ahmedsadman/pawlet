# Pawlet mobile app

Flutter app. Run every command in this file from `mobile-app/`.

## Toolchain paths

Neither `adb` nor `java` is on `PATH` — use the absolute paths below instead of
searching for them.

| Tool | Path |
|---|---|
| `adb` | `~/Android/Sdk/platform-tools/adb` |
| Android SDK | `~/Android/Sdk` |
| Java (JDK 25, Android Studio's bundled JBR) | `/snap/android-studio/current/jbr` |

Android Studio is a snap, so its revision directory (`/snap/android-studio/244`)
changes on update — always go through `current`, which is a stable symlink.
`flutter doctor -v` reports the resolved revision path; both point at the same JDK.

## Debug build

```bash
flutter build apk --debug
```

Or run straight onto a connected device:

```bash
flutter run --debug
```

Debug builds get `applicationIdSuffix = ".debug"`, i.e. package
`com.pastabyte.pawlet.debug`, labelled "Pawlet Debug". They install alongside a
release build (`com.pastabyte.pawlet`) and keep separate data.
