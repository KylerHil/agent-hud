# Homebrew cask for Agent HUD. scripts/release.sh fills in the version and checksum and publishes this
# to github.com/KylerHil/homebrew-tap as Casks/agent-hud.rb. Edit it here, not in the tap.
cask "agent-hud" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/KylerHil/agent-hud/releases/download/v#{version}/AgentHUD-#{version}.zip"
  name "Agent HUD"
  desc "Floating panel and menu bar for every Claude Code and Codex session"
  homepage "https://github.com/KylerHil/agent-hud"

  livecheck do
    url :url
    strategy :github_latest
  end

  # The hook installer edits JSON with jq (built into macOS 15+, not 14).
  depends_on formula: "jq"
  depends_on macos: :sonoma

  app "AgentHUD.app"
  # The hook reporter, on PATH as `agenthud-report` (install-hooks, hooks-status, uninstall-hooks).
  binary "#{appdir}/AgentHUD.app/Contents/MacOS/agenthud-report"

  # The app isn't notarized (it's shared from source, not the App Store), so skip the Gatekeeper
  # quarantine that would otherwise block the first launch.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/AgentHUD.app"], must_succeed: false
  end

  uninstall quit: "com.xeratec.agenthud"

  # `brew uninstall --zap` also takes Agent HUD's hooks out of ~/.claude and ~/.codex (with backups).
  zap script: {
        executable:   "#{Dir.home}/.agenthud/bin/agenthud-report",
        args:         ["uninstall-hooks", "--yes"],
        must_succeed: false,
      },
      trash:  [
        "~/.agenthud",
        "~/Library/Preferences/com.xeratec.agenthud.plist",
      ]

  caveats <<~EOS
    Open Agent HUD, then Settings (gear) → Hooks → Install Hooks… so Claude Code and Codex
    report to it. Or run: agenthud-report install-hooks
  EOS
end
