import SwiftUI

/// Hook install status and actions. Filled in by the installer phase.
struct HooksPane: View {
    var body: some View {
        Text("Run `make install-hooks` to connect Claude Code and Codex.").font(.caption)
    }
}
