# Releasing Boopr (signed + notarized DMG)

This produces a **Developer-ID-signed, Apple-notarized, stapled `.dmg`** that
opens on anyone's Mac with **no Gatekeeper warning** — no "unidentified
developer", no right-click→Open, no `xattr` dance.

After a one-time setup, the whole thing is a single command:

```sh
scripts/release.sh
```

---

## One-time setup

### 1. Developer ID Application certificate

You need a **Developer ID Application** certificate. This is *not* the same as
the "Apple Development" or "Apple Distribution" certs you may already have —
those are for Xcode debug builds and the App Store. Check what you've got:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application" || echo "none yet"
```

> ⚠️ Developer ID certificates are only available to an **Individual** Apple
> Developer account, or the **Account Holder** of an Organization team.

**Easiest — via Xcode** (30 seconds):
Xcode → Settings → Accounts → select your team → **Manage Certificates…** →
**+** → **Developer ID Application**. Done — it lands in your login keychain.

**Fully from the terminal** (keeps the private key local; only the cert is public):

```sh
# 1. generate a private key + certificate signing request
openssl genrsa -out devid.key 2048
openssl req -new -key devid.key -out devid.csr \
  -subj "/CN=Boopr Developer ID/emailAddress=YOU@example.com"
```

Upload `devid.csr` at <https://developer.apple.com/account/resources/certificates/add>
→ **Developer ID Application** → download `developerID_application.cer`, then:

```sh
# 2. import BOTH the private key and the issued certificate into the login keychain.
#    (openssl wrote the key to a local file, so unlike the Xcode path it isn't in
#    the keychain yet — the cert is only a usable signing identity once its key is too.)
security import devid.key -k ~/Library/Keychains/login.keychain-db
security import developerID_application.cer -k ~/Library/Keychains/login.keychain-db
```

> If `security import` of the certificate reports `MAC verification failed` for a
> `.p12`, import the key and cert as separate files (as above) instead of bundling
> them into a `.p12` — OpenSSL 3 PKCS#12 files don't always import cleanly.

Confirm it's there and note the exact identity string:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
# → e.g.  "Developer ID Application: Your Name (TEAMID)"
```

### 2. Notarization credentials

`release.sh` notarizes via a **keychain profile** so no secrets live in the
repo or get passed on the command line.

**Recommended — App Store Connect API key** (best for automation/CI):

1. App Store Connect → **Users and Access → Integrations → App Store Connect
   API → Keys** → **+**. Role: *Developer*. Download `AuthKey_XXXXXX.p8`
   (downloadable **once**). Note the **Key ID** and the **Issuer ID** on that page.
2. Store it:

```sh
xcrun notarytool store-credentials "boopr-notary" \
  --key ~/path/to/AuthKey_XXXXXX.p8 \
  --key-id KEYID \
  --issuer ISSUER-UUID
```

**Alternative — Apple ID + app-specific password:**

```sh
# make an app-specific password at https://appleid.apple.com → Sign-In & Security
xcrun notarytool store-credentials "boopr-notary" \
  --apple-id "you@example.com" --team-id TEAMID --password "abcd-efgh-ijkl-mnop"
```

Verify the profile works:

```sh
xcrun notarytool history --keychain-profile "boopr-notary"
```

---

## Cut a release

```sh
scripts/release.sh
```

It runs end to end:

1. builds the universal (arm64 + x86_64) app via `build-app.sh`,
2. signs it with your Developer ID + **hardened runtime** + `Resources/boopr.entitlements` + a secure timestamp,
3. **notarizes** the app and **staples** the ticket,
4. builds the `.dmg` (app + Applications alias + READ ME),
5. signs, notarizes, and staples the `.dmg`,
6. verifies with `spctl` / `stapler`.

Output: `dist/Boopr-<version>.dmg`.

Override the identity or notary profile if needed:

```sh
DEV_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="boopr-notary" \
scripts/release.sh
```

Bump the version first by editing `CFBundleShortVersionString` in
`Resources/Info.plist`.

---

## Verify it's good

```sh
spctl -a -t open --context context:primary-signature -vv dist/Boopr-*.dmg
xcrun stapler validate dist/Boopr-*.dmg
```

You want `accepted` and `source=Notarized Developer ID`.

---

## Publish

Attach the DMG to a GitHub release:

```sh
gh release create v0.1.0 dist/Boopr-0.1.0.dmg \
  --title "Boopr 0.1.0" --notes "First signed + notarized release."
```

Then the README's "Download the `.dmg` from Releases" path Just Works.

---

## Notes & troubleshooting

- **What's signed:** Boopr drives Ghostty via AppleScript, so under the hardened
  runtime it needs `com.apple.security.automation.apple-events`
  (`Resources/boopr.entitlements`). It is **not** sandboxed — direct Developer ID
  distribution, not the App Store.
- **First notarization** can take a few minutes; `--wait` blocks until Apple
  finishes. Subsequent runs are usually under a minute.
- **If notarization is rejected**, get the reasons:
  ```sh
  xcrun notarytool log <submission-id> --keychain-profile boopr-notary
  ```
  (the submission id is printed by `notarytool submit`.)
- **`make-signing-cert.sh` / `lib-sign.sh`** are a *local-dev* convenience (a
  self-signed cert so TCC grants survive rebuilds) — unrelated to this
  distribution flow. Once you ship notarized DMGs, end users never touch them.
- **Universal binary:** the DMG runs on both Apple Silicon and Intel.
