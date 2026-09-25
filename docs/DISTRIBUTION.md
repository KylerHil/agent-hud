# Shipping Agent HUD

Two channels, one command each once the setup below is done:

| | Direct download (Developer ID) | Mac App Store / TestFlight |
|---|---|---|
| Command | `make release-direct` | `make upload-appstore` |
| Output | notarized `build/dist/AgentHUD-<version>.dmg` | `build/dist/AgentHUD-<version>-<build>.pkg`, uploaded |
| Features | everything | everything except chat watching (Accessibility isn't allowed in the sandbox) |
| Review | none; Apple notarizes in minutes | App Review; see the risks in [APP_STORE.md](APP_STORE.md) |
| Updates | you host the DMG (website, GitHub Releases) | through the App Store |

**Recommendation:** start with TestFlight to find out early whether the sandboxed build works
and whether review accepts it, and ship the Developer ID DMG alongside. It has no review risk
and all features.

## One-time setup (about 30 minutes)

You need to be in the Xeratec Apple Developer Program team. Creating Developer ID certificates
requires the **Account Holder** role.

### 1. Team ID

developer.apple.com → Account → **Membership details** → *Team ID* (10 characters).

### 2. Certificates

Xcode → Settings → Accounts → select the Xeratec team → **Manage Certificates…** → **+**, and add:

- **Developer ID Application**: for the direct DMG
- **Apple Distribution**: signs the App Store app
- **Mac Installer Distribution**: signs the App Store `.pkg`. It shows in the keychain as
  "3rd Party Mac Developer Installer: …"

Check that they're installed:

```sh
security find-identity -v                  # all three should be listed
```

### 3. App ID

developer.apple.com → Certificates, IDs & Profiles → **Identifiers** → **+** → App IDs → App →
Platform **macOS**, Bundle ID **explicit** `com.xeratec.agenthud`, Description "Agent HUD".
No capabilities need to be enabled. The App Group is prefixed with your Team ID
(`<TEAM_ID>.com.xeratec.agenthud`), which macOS allows without registration. If upload validation
complains about the App Group anyway, enable **App Groups** on this App ID, add that group, and
regenerate the profile in step 4.

### 4. Provisioning profile (App Store only)

**Profiles** → **+** → Distribution → **Mac App Store Connect** → the App ID above → the Apple
Distribution certificate → name it "Agent HUD App Store" → **Download**. Save it as:

```
Distribution/AgentHUD_AppStore.provisionprofile       # git-ignored
```

### 5. App record

appstoreconnect.apple.com → **Apps** → **+** → New App → Platform **macOS**, Name **Agent HUD**,
Primary language English (U.S.), Bundle ID `com.xeratec.agenthud`, SKU `agenthud`,
Full access. Fill in the listing from [APP_STORE.md](APP_STORE.md) now or before you submit.

### 6. App Store Connect API key (uploads)

App Store Connect → **Users and Access** → **Integrations** → App Store Connect API → Team Keys → **+**
→ name "Agent HUD uploads", access **App Manager** → download the `.p8` (you only get one chance):

```sh
mkdir -p ~/.appstoreconnect/private_keys
mv ~/Downloads/AuthKey_XXXXXXXXXX.p8 ~/.appstoreconnect/private_keys/
```

Note the **Key ID** and the **Issuer ID** shown above the key list.

### 7. Notarization credentials (direct DMG)

Create an app-specific password at account.apple.com → Sign-In and Security → App-Specific
Passwords, then store it in the keychain once:

```sh
xcrun notarytool store-credentials agenthud-notary \
  --apple-id you@xeratec.com --team-id <TEAM_ID> --password <app-specific-password>
```

### 8. Config file

```sh
cp Distribution/config.env.example Distribution/config.env   # git-ignored
```

Fill in `TEAM_ID`, the three identity names exactly as `security find-identity -v` prints them,
`ASC_KEY_ID`, and `ASC_ISSUER_ID`.

## Every release

1. Bump **CFBundleShortVersionString** in `Resources/Info.plist` (e.g. `1.0.1`). The build number is
   set automatically (`yyMMddHHmm`, always increasing); override with `BUILD_NUMBER=…`.
2. `make test`.
3. Build and ship:

### TestFlight

```sh
make upload-appstore
```

This builds universal binaries (Apple silicon and Intel), signs them for App Sandbox, packages a
`.pkg`, validates it with App Store Connect, and uploads it. After processing (usually 10–30 min,
you get an email):

- App Store Connect → your app → **TestFlight**. The build shows under macOS builds. Export
  compliance is already answered: `ITSAppUsesNonExemptEncryption` is `false`.
- **Internal testing:** add yourself and teammates to an internal group. They install it with the
  TestFlight app on their Mac, with no review.
- **External testing:** create an external group and submit the build for **Beta App Review**
  (usually about a day).
- Work through the checklist in [APP_STORE.md](APP_STORE.md#testflight-checklist) on a real Mac.

### App Store

App Store Connect → your app → **App Store** tab → the version (e.g. 1.0) → **Build** → pick the
TestFlight build → complete the listing, App Privacy, age rating and review notes (all in
[APP_STORE.md](APP_STORE.md)) → **Add for Review** → **Submit**.

### Direct download

```sh
make release-direct
```

This signs with Developer ID and the hardened runtime, builds the DMG, notarizes it, and staples
the ticket. Upload `build/dist/AgentHUD-<version>.dmg` wherever you host downloads. Opening it on
any Mac shows no Gatekeeper warning.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Missing Distribution/config.env` | Step 8. |
| `no identity found` / `ambiguous` | Identity strings in `config.env` must match `security find-identity -v` exactly. |
| Notarization "Invalid" | `xcrun notarytool log <submission-id> --keychain-profile agenthud-notary` shows the reason; usually an unsigned nested binary. |
| Upload: "Invalid Provisioning Profile" | The profile must be *Mac App Store Connect* for `com.xeratec.agenthud`, made with the same Apple Distribution certificate. |
| Upload: "bundle version must be higher" | Build numbers only go up; the default timestamp handles this. Don't reuse `BUILD_NUMBER`. |
| `altool` removed in a future Xcode | Upload the `.pkg` with **Transporter** (free on the Mac App Store): drag it in, Deliver. |
| TestFlight build works but shows no sessions | Hooks point at the reporter inside the app: install them from Settings → Hooks in the TestFlight build. |

## What's in the repo

```
Distribution/config.env.example             fill in and copy to config.env
Distribution/entitlements/direct.entitlements          hardened runtime + AppleScript
Distribution/entitlements/appstore-app.entitlements    App Sandbox, App Group, file/AppleScript exceptions
Distribution/entitlements/appstore-reporter.entitlements  the hook reporter's own sandbox
Resources/PrivacyInfo.xcprivacy             privacy manifest (no tracking, no data collected)
scripts/release.sh                          everything above; `make release-direct|release-appstore|upload-appstore`
```
