# Build and release

## Building

`./create-app.sh` builds the release binary for Apple silicon and assembles
`Rota.app`: the version from the latest `vX.Y.Z` tag (`0.0.0` before the first
one; CI refuses a build without a tag), a check that the binary carries the
macOS 26 SDK stamp from `Package.swift`, the embedded Sparkle framework, and
the Info.plist, and one `Assets.car` compiled by `actool` from the Icon
Composer icon (`App Icon.icon`) and the menu bar template images
(`MenuIcons.xcassets`). `scripts/draw-icon.py` writes both from one
geometry, the icon's `icon.json` included; change the script and rerun it
rather than editing its output.

## Signing and notarization

`create-app.sh` signs with the team's Developer ID Application identity when
the keychain has it (hardened runtime, and with `RELEASE=1` a secure
timestamp); without it the bundle is signed ad hoc and macOS treats every
build as a new app. `RELEASE=1 ./create-app.sh && ./notarize.sh` notarizes,
staples, and writes `Rota-vX.Y.Z-macOS.zip`.

Rota is not sandboxed and ships no entitlements file. The hardened runtime
does not restrict spawning child processes, so the harness CLIs and `zsh` run
as they do from a terminal. TCC charges a child's privacy requests to Rota as
the responsible process, so a routine that drives another app through
`osascript` would need `com.apple.security.automation.apple-events` (and an
`NSAppleEventsUsageDescription`); add both only when such a routine is
supported.

## Release process

A pushed annotated `vX.Y.Z` tag runs `.github/workflows/build.yml`: lint and
tests, a temporary keychain with the Developer ID identity and the notarytool
profile, `RELEASE=1 ./create-app.sh`, `./notarize.sh`, then the Sparkle
`appcast.xml` (this release only, EdDSA-signed, with the tag body embedded as
Markdown release notes), and the GitHub Release with the zip, the appcast, the
tag's first line as its title and its body as the notes. CI refuses a
lightweight tag or one without a body. Branch and pull request builds are
signed ad hoc and uploaded as a workflow artifact.

The repository secrets it reads are `DEVELOPER_ID_P12_BASE64`,
`DEVELOPER_ID_P12_PASSWORD`, `NOTARY_KEY_P8_BASE64`, `NOTARY_KEY_ID`,
`NOTARY_ISSUER_ID`, and `SPARKLE_PRIVATE_KEY`, the same set every app of the
team uses. Only tag builds read them; GitHub never passes them to pull requests
from forks. Their source is the 1Password item "Apple Developer ID: Victor
Kuznetsov (K2GT9Q4S6U)" (Private vault), which also holds the restore commands
and the Sparkle key.

## Sparkle

`Updater` (in the `Rota` target) runs `SPUStandardUpdaterController` with
gentle reminders: a scheduled check that finds an update while Rota is not in
front publishes `pendingVersion` instead of opening a window. `create-app.sh`
copies `Sparkle.framework` into `Contents/Frameworks`, adds the
`@executable_path/../Frameworks` rpath, removes its XPC services (they exist
for sandboxed apps), ships its MIT license, and signs `Autoupdate`,
`Updater.app`, the framework and the app in that order. One EdDSA key serves
every app of the team; `SUPublicEDKey` in `create-app.sh` is its public half,
and `SURequireSignedFeed` makes the app reject a feed that is not signed with
it. `SUFeedURL` points at the latest release's `appcast.xml`.

## Bundle identifier

`com.wiltodelta.rota`. Keep it: the settings, notification permission and login
item are keyed to it.

## Verify a release

```bash
gh release download vX.Y.Z -R wiltodelta/rota -p "*.zip" -D /tmp/asset-check && \
  ditto -x -k /tmp/asset-check/*.zip /tmp/asset-check/app && \
  spctl -a -vv /tmp/asset-check/app/Rota.app && \
  xcrun stapler validate /tmp/asset-check/app/Rota.app
```

Unregister the extracted copy before deleting it
(`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u /tmp/asset-check/app/Rota.app`):
LaunchServices keeps a deleted copy registered under the bundle id otherwise.
