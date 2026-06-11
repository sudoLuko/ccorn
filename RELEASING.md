# Releasing CCorn

Releases ship as a **signed, notarized, stapled** `CCorn.app` zipped for GitHub
Releases. Notarization requires an Apple Developer Program membership; nothing
credential-shaped is ever committed — identity and notary auth live in your
keychain and reach the script through the environment.

## One-time setup

1. **Developer ID certificate.** In your Apple Developer account, create a
   *Developer ID Application* certificate and install it in your login
   keychain. Confirm with:

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

2. **Notary credentials.** Create an app-specific password for your Apple ID
   (appleid.apple.com → Sign-In and Security → App-Specific Passwords), then
   store a notarytool profile in the keychain (the password is prompted, not
   recorded):

   ```sh
   xcrun notarytool store-credentials ccorn-notary \
       --apple-id "you@example.com" \
       --team-id "TEAM123456"
   ```

## Cutting a release

1. Bump `MARKETING_VERSION` in `project.yml` if needed (the script reads the
   version from there), commit, and tag.
2. Run the preflight suite against the current Claude Code CLI
   (`scripts/preflight/README.md`) — it catches TUI wording drift that breaks
   state detection.
3. Build, sign, notarize, staple, package:

   ```sh
   export CCORN_SIGN_IDENTITY="Developer ID Application: Your Name (TEAM123456)"
   export CCORN_NOTARY_PROFILE="ccorn-notary"
   scripts/release.sh
   ```

   The script waits for Apple's notarization verdict (usually a few minutes),
   staples the ticket, and finishes by running
   `scripts/preflight/release-gatecheck.sh` against the artifact: the binary
   must carry no debug surface, `codesign --verify --strict` must pass, `spctl`
   must accept the app *with* a browser-style quarantine stamp, and
   `stapler validate` must succeed.

4. Upload `dist/CCorn-v<version>.zip` to the GitHub release.

Because the app is notarized and stapled, a downloaded copy opens without any
Gatekeeper override; the only first-run prompt users see is the standard
"downloaded from the Internet" confirmation, plus the AppleEvents permission
ask the first time CCorn opens a session in Terminal.
