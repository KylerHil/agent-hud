# Releasing Agent HUD

Releases go out through Homebrew. There's no App Store and no notarization.

- **This repo (`KylerHil/agent-hud`):** each version is a GitHub Release with
  `AgentHUD-<version>.zip` attached. The app inside is a universal, ad-hoc signed build.
- **The tap (`KylerHil/homebrew-tap`):** holds `Casks/agent-hud.rb`, which points at that zip.
  Users install with `brew install --cask kylerhil/tap/agent-hud`.

The cask's source is [`packaging/agent-hud.rb`](../packaging/agent-hud.rb). Edit it there; the release
script fills in the version and checksum and pushes it to the tap.

## Cutting a release

From a clean `main`, logged in with `gh auth login`:

```sh
make release VERSION=1.2.0
```

That runs the tests and then:

1. Sets the version in `Resources/Info.plist` and commits "Release 1.2.0".
2. Builds for Apple silicon and Intel, assembles and ad-hoc signs `AgentHUD.app`, and zips it.
3. Tags `v1.2.0`, pushes `main` and the tag, and creates the GitHub Release with the zip and
   auto-generated notes.
4. Writes the cask with the new version and SHA-256 into the tap and pushes it.

Everyone gets it with `brew upgrade --cask agent-hud`. Brew also notices on its own schedule.

To try the build and cask without publishing anything:

```sh
make release-dry-run VERSION=1.2.0     # → build/release/AgentHUD-1.2.0.zip and agent-hud.rb
brew style --cask build/release/agent-hud.rb
```

## If something goes wrong

| Problem | Fix |
|---|---|
| "tag v1.2.0 already exists" | Pick the next version; tags are never reused. |
| Release created but tap push failed | Rerun just the tap step: clone `KylerHil/homebrew-tap`, copy `build/release/agent-hud.rb` to `Casks/`, commit, push. |
| Users see "damaged" / "can't be opened" | They installed the zip by hand: `xattr -dr com.apple.quarantine /Applications/AgentHUD.app`, or right-click → Open. The cask does this itself. |
| Need to pull a bad release | `gh release delete v1.2.0 --cleanup-tag`, then point the tap back at the previous version (revert its last commit). |

## Later: notarizing

The ad-hoc signed build works everywhere through Homebrew. If you ever want downloads that open
with no Gatekeeper prompt at all (outside Homebrew), sign with a Developer ID certificate using
`codesign --options runtime` and submit with `xcrun notarytool`. Plug that into `scripts/release.sh`
in place of the ad-hoc `codesign` lines.
