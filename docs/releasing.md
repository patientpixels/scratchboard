# Releasing

Releases are Developer ID-signed, notarized `.zip`s on GitHub. Sparkle finds them through `appcast.xml`.

## One-time setup

1. **Apple Developer Program** membership (paid, for the team that will sign releases).
2. **Developer ID Application certificate.** In Xcode: Settings → Accounts → your team → Manage Certificates → + → *Developer ID Application*. Only the team's Account Holder can create it. Check it's there:
   ```sh
   security find-identity -v -p codesigning   # shows "Developer ID Application: <name> (<TEAM_ID>)"
   ```
   The 10-character ID in parentheses is your `TEAM_ID`.
3. **Notary credentials** in the Keychain. Create an app-specific password at [account.apple.com](https://account.apple.com) (Sign-In and Security → App-Specific Passwords), then:
   ```sh
   xcrun notarytool store-credentials scratchboard-notary --apple-id <your Apple ID> --team-id <TEAM_ID>
   ```
   It prompts for the app-specific password and stores everything under the profile name `scratchboard-notary`.
4. **Sparkle update key.** Already generated, with the private key in the login Keychain under the account `scratchboard`. The public key is `SUPublicEDKey` in `Scratchboard/Info.plist`. **Back up the private key**: if it's lost, installed copies can never be updated again.
   ```sh
   generate_keys --account scratchboard -x sparkle-private-key   # store it in your password manager, then delete the file
   ```
   (`generate_keys` lives in `.build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/` after a build.)

## Each release

1. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`, which must always increase) in the project, commit and push.
2. Run:
   ```sh
   TEAM_ID=<TEAM_ID> scripts/release              # optional: NOTES=notes.md
   ```
   It archives, exports with Developer ID, notarizes and staples, zips, signs the update for Sparkle, adds it to `appcast.xml`, tags `vX.Y.Z`, creates the GitHub release and pushes the appcast.
