# Permanent signing and recovery

The original v1.0.0 test APK and v1.0.1 categories APK used different temporary debug signing keys. Their private keys were not retained. Neither APK contains a recoverable private key. A new key cannot authorize an in-place update of those installations.

## Protect existing records first

Keep the working app installed. Settings → Export backup. Save the ZIP outside the app's private storage. Keep a second copy. This includes months, expenses and bills. Do not clear storage or uninstall to troubleshoot signing.

## One-time permanent key setup (owner action)

The ChatGPT repository connector cannot create repository secrets. Open a trusted GitHub Codespace for this repository, then run:

```
python3 tool/setup_signing.py
```

The script requires an authenticated `gh` CLI allowed to manage this repository's Actions secrets and JDK `keytool`. It asks for a strong password, creates a password-protected PKCS12 signing key, and uploads the existing workflow's four signing secrets via stdin. It never prints passwords, adds credentials to source, or replaces an existing key/secrets. If permissions fail, keep the generated key; do not generate another identity. Store the same four values in GitHub Settings → Secrets and variables → Actions from that trusted environment.

Download `.signing-backup/daily-expenses-permanent.p12` to private storage and retain its password before deleting the Codespace. The directory is ignored by Git. Do not paste secrets into this chat or commit them.

Actions → Android APK → Run workflow produces only a signed release APK. Pushes and pull requests validate source but do not distribute APKs. Missing signing secrets stop release builds. Future releases reuse these secrets, the same application ID and increasing versionCode.

## Migration remains pending

Permanent signing does not repair the original lost debug key. Before replacing any installed test version, the backup must be available and validated. No automatic phone access or installation is available here. A one-time replacement may require removing the old installation; do not perform that step until the backup and recovery procedure have been checked with the owner. Normal future updates must install over the permanently signed app without uninstalling or clearing data.
