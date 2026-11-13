#!/usr/bin/env python3
"""Run once in the owner's trusted GitHub Codespace. No passwords in source/logs."""
import base64
import getpass
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

REPO = 'kumarpersonal23/daily-expenses'
SECRET_NAMES = ['ANDROID_KEYSTORE_BASE64', 'ANDROID_STORE_PASSWORD', 'ANDROID_KEY_PASSWORD', 'ANDROID_KEY_ALIAS']

def run(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, **kwargs)

def main():
    if not all(shutil.which(x) for x in ['gh', 'keytool']):
        raise RuntimeError('GitHub CLI and JDK keytool are required. Run in your GitHub Codespace.')
    current = json.loads(run(['gh', 'secret', 'list', '--repo', REPO, '--json', 'name'], text=True).stdout)
    if any(x['name'] in SECRET_NAMES for x in current):
        raise RuntimeError('Signing secrets already exist. Stopped to avoid replacing the permanent signing identity.')
    password = getpass.getpass('Choose a strong signing password (at least 16 characters; remember it): ')
    if len(password) < 16 or '\n' in password or '\r' in password:
        raise RuntimeError('Use at least 16 characters, without line breaks.')
    if password != getpass.getpass('Confirm password: '):
        raise RuntimeError('Passwords do not match.')
    directory = Path('.signing-backup')
    directory.mkdir(mode=0o700, exist_ok=True)
    key = directory / 'daily-expenses-permanent.p12'
    if key.exists():
        raise RuntimeError('A signing backup already exists. Stopped; do not generate another key.')
    env = dict(os.environ, DAILY_SIGNING_PASSWORD=password)
    run(['keytool', '-genkeypair', '-storetype', 'PKCS12', '-keystore', str(key),
         '-alias', 'daily-expenses', '-keyalg', 'RSA', '-keysize', '3072', '-validity', '10000',
         '-dname', 'CN=Daily Expenses', '-storepass:env', 'DAILY_SIGNING_PASSWORD',
         '-keypass:env', 'DAILY_SIGNING_PASSWORD'], env=env)
    key.chmod(0o600)
    values = [base64.b64encode(key.read_bytes()), password.encode(), password.encode(), b'daily-expenses']
    for name, value in zip(SECRET_NAMES, values):
        run(['gh', 'secret', 'set', name, '--repo', REPO], input=value)
    print('Permanent signing secrets saved. No credentials were printed.')
    print('Download .signing-backup/daily-expenses-permanent.p12 to private storage and retain its password.')
    print('Never commit the key or paste its password into chat. Do not delete the Codespace before downloading the backup.')
    print('Next: Actions > Android APK > Run workflow. Only signed release APKs will be distributed.')

if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        # Never echo command stderr: tools may include sensitive arguments or inputs.
        if isinstance(exc, subprocess.CalledProcessError):
            print('GitHub or keytool rejected the operation. Keep any .signing-backup file; do not regenerate the key. Check account permissions.', file=sys.stderr)
        else:
            print(str(exc), file=sys.stderr)
        sys.exit(1)
