# Daily Expenses — Android

An offline Flutter/Dart expense ledger with Drift/SQLite, compact Material 3 UI, private bill files, image/PDF viewing, PIN access lock and ZIP backup/restore.

Permanent application ID: **com.dailyexpenses.personal**. Version **1.0.0+1**. Android 7.0/API 24 or later.

## Use
- Pick a month from the header. A new month starts on day 1, independently of today's actual date.
- Settings → opening amount → Save. The opening amount is obscured; the balance is hidden by default.
- Enter particulars and rupees, optionally attach multiple bills, then tap the arrow. Keyboard Next moves to amount, Done saves.
- Close Day / Next saves a valid unfinished entry and closes the active date in one transaction. An incomplete entry prevents closing. The final day completes the month.
- Previous dates show one summary each. Expand to inspect or edit without changing the active date. The history icon explicitly reopens a date.
- Edit uses the bottom row. Checkmark saves the same record; X cancels; trash asks for confirmation. Serial numbers are consecutive display positions within each day.
- Bill icon → attach/view bills for that expense. View Bills → search, filter, view, zoom, share, replace or remove bills.
- Settings → backup exports all months and bills; restore validates the archive and replaces all records atomically. Existing PIN stays on the phone.

## Privacy
No accounts, ads, analytics or INTERNET permission. SQLite and bill files are in Android private app storage. **The SQLite database and exported backups are not encrypted.** The PIN uses PBKDF2-HMAC-SHA256, 210,000 iterations and a random 32-byte salt; the credential is in Android secure storage, with attempt throttling. PIN access is not equivalent to database encryption. Opening amount is protected by Android's app sandbox and UI concealment. Backups contain readable private financial data; keep them private.

Android auto-backup is disabled. Screenshots and app-switcher snapshots are blocked with FLAG_SECURE. Camera and document selection use system pickers; broad storage permissions are not requested. PIN is not exported; there is no recovery backdoor. A new installation can restore a saved backup without the old PIN. Forgetting a PIN with no backup risks losing access to local data.

## Architecture
- `lib/database`: Drift tables and non-destructive v1→v2 migration.
- `lib/repositories`: ledger transactions and database-backed sums.
- `lib/models`: exact integer money/date utilities.
- `lib/services`: private files, secure PIN, validated backup, shared operation lock.
- `lib/ui`: compact ledger, settings, bill list and viewers.
- `test`: ledger, dates, constraints, attachment persistence, restore rollback, migrations and widget interactions.

Settings, months, days, expenses, expense_attachments and categories have relational constraints. One open day per month is enforced by a partial unique index. Money is integer paise. Totals are SQL SUM queries. Files are copied before database references commit; deletion removes references before files. A crash may leave harmless unreferenced files, never intentionally delete a referenced bill. Restore copies new bills under fresh names, validates fixed table/column allowlists, inserts through the existing schema in a transaction, and retains the old files for crash safety. Imported database triggers and SQL are never executed.

Attachments: JPEG/PNG/PDF content signatures, up to 25 MB each. Backup import limit: 512 MB compressed and expanded. Current ZIP implementation is memory-based; very large backups may require a future streaming implementation on low-memory phones. Missing bills are shown as recoverable records; replace or remove them before exporting a complete backup.

## Reproduce checks and APK
Pinned Flutter **3.38.5**, Dart **3.10.4**, JDK **17**, compile/target Android **36**. Commit `pubspec.lock`. Use an Android SDK with platform 36; Gradle can install licensed missing components.

```sh
flutter pub get --enforce-lockfile
dart run build_runner build --delete-conflicting-outputs
flutter analyze
flutter test --reporter expanded
flutter build apk --debug
```

Generated Drift `.g.dart` is included for review but regenerate after any schema edit. `tool/check.sh` runs generation, formatting, analysis and tests. Android Gradle wrapper is included.

## Phone-only cloud build
1. Create a private GitHub repository in your phone browser. Upload the **extracted project contents**, not just the ZIP. Include `.github/workflows/android.yml`, `pubspec.lock`, Android wrapper and `lib/`.
2. If the mobile GitHub upload UI cannot preserve nested folders, use GitHub Codespaces in desktop-browser mode, upload the ZIP there, unzip and commit/push its contents. The app itself remains fully offline; this is only a developer build step.
3. Open Actions → Android APK → Run workflow. Leave release unchecked for a debug test APK.
4. A successful run publishes a `Daily-Expenses-<run>` artifact. Download/extract it on your phone and tap the APK. Allow installation from that browser/file manager when Android asks.
5. The workflow is supplied as source; it is not automatically connected to your GitHub account or triggered by this archive.

## Release signing — required before long-term use
Debug builds are for testing. GitHub's default debug key can change between runners; do not rely on it for future in-place updates. A release build is deliberately blocked unless `android/key.properties` exists. The production signing key must be created once and retained securely by you. Never commit it, its passwords or key.properties.

Create a JKS using `keytool` in a trusted developer environment (or private cloud terminal), choosing strong unique passwords interactively:

```sh
keytool -genkeypair -v -keystore daily-expenses-release.jks -alias daily-expenses -keyalg RSA -keysize 3072 -validity 10000
```

In GitHub repository Settings → Secrets and variables → Actions, set:
- `ANDROID_KEYSTORE_BASE64`: base64 representation of that JKS (secret, never paste in issues or chat).
- `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_PASSWORD`, `ANDROID_KEY_ALIAS`.

Keep a separate secure offline backup of the JKS and passwords. Run the workflow with release checked. Signing credentials are decoded only on the ephemeral runner, used for signing and removed in the final cleanup step. Record the public SHA-256 signing certificate fingerprint with each release. First switching from a debug installation to a differently signed release cannot be an ordinary in-place update: export a backup first and use a carefully planned one-time migration. Set up production signing before storing irreplaceable records.

For local release builds, `android/key.properties` contains `storeFile`, `storePassword`, `keyPassword`, `keyAlias`; use an absolute keystore path. This file is excluded from Git and delivered archives.

## Future updates without data loss
Send the latest source ZIP or repository, installed version/build number, release certificate fingerprint, and the desired change. Do not send private signing keys/passwords. Ask: “Update Daily Expenses, retain com.dailyexpenses.personal and the same signing identity, increment versionCode, migrate SQLite without deleting records or bills, run preservation tests, and build an update APK.”

Install the matching-signed newer APK over the existing app using Android's Update action. Never use uninstall/reinstall or Clear storage as the update method. Export a backup before significant upgrades. `AGENTS.md` records the maintenance contract. VersionCode is controlled by the `+number` in pubspec.yaml; increase it for every distributed update, including CI builds. CI does not silently derive it from run numbers because those can reset on repository moves.

## Device acceptance checklist
Verify camera/gallery/PDF pickers, process-death photo recovery, full PDF/image viewing, sharing, PIN lock after leaving the app, export to a user-selected folder, restore, keyboard visibility, accessibility text scaling, and install-over-existing-data on your actual phone. Automated tests do not substitute for these Android integration checks.
