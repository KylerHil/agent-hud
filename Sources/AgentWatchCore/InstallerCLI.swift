import Foundation

/// Subcommands of agentwatch-report other than reporting. Filled in by the hook installer phase.
public enum InstallerCLI {
    public static func run(command: String, args: [String]) -> Int32 {
        FileHandle.standardError.write(Data("agentwatch-report: unknown command '\(command)'\n".utf8))
        return 64
    }
}
