import AgentHUDCore
import Foundation

// agenthud-broker: owns the agent sessions and pairs the Coordinator starts, so they outlive the app.
// Agent HUD launches it on demand; it exits after ten idle minutes. See docs/Coordinator-Plan.md §9.7.
if !BrokerService().run() { exit(1) }
