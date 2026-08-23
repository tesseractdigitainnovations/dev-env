# Android agent test matrix

Provisions three Android AVDs on the Ubuntu host and keeps them **stopped by default**.

## Matrix

- `app-api34` — Android 14 / Google APIs / x86_64
- `app-api35` — Android 15 / Google APIs / x86_64
- `app-api36` — Android 16 / Google APIs / x86_64

The kit intentionally does **not** run `android emulator create <profile>`, because that path may select/download a default Play Store image. It uses Android CLI for SDK packages and `avdmanager` to bind each AVD to the exact requested Google APIs system image.

## Provision

```bash
chmod +x provision-android-matrix.sh
./provision-android-matrix.sh
```

No emulator is started by provisioning and there is no systemd service.

## Start on demand

```bash
android-test-start app-api35
```

Check:

```bash
android-test-status
adb devices
```

Wait for boot:

```bash
android-test-wait emulator-5554
```

Install APK:

```bash
android-test-install emulator-5554 ./app-debug.apk
```

Screenshot:

```bash
android-test-screenshot emulator-5554
```

Logs:

```bash
android-test-logs emulator-5554
```

Stop:

```bash
android-test-stop
```

Clean/wipe and start:

```bash
android-test-reset app-api35
```

## Notes

The three system images are Google APIs images, not Google Play images. No `google_apis_playstore` package is requested by these scripts.
