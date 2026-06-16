import Foundation
import Testing

/// The launch-config argv builder. The two CLI rules that must never break are
/// pinned here: `--dangerously-skip-permissions` never co-occurs with
/// `--permission-mode`, and `standard` carries no permission flag at all.
@Suite struct LaunchConfigTests {

    // MARK: Permission-mode arm → tokens

    @Test func standardEmitsNoPermissionFlag() {
        let tokens = SessionLaunchConfig(permissionMode: .standard).claudeFlagTokens()
        #expect(!tokens.contains("--permission-mode"))
        #expect(!tokens.contains("--dangerously-skip-permissions"))
        #expect(!tokens.contains("--allow-dangerously-skip-permissions"))
    }

    @Test func routineModesEmitPermissionModeWithCLISpelling() {
        for mode: CCPermissionMode in [.plan, .acceptEdits, .auto] {
            let tokens = SessionLaunchConfig(permissionMode: mode).claudeFlagTokens()
            // The pair appears in order, and the value is the CLI's own spelling.
            let idx = tokens.firstIndex(of: "--permission-mode")
            #expect(idx != nil)
            if let idx { #expect(tokens[idx + 1] == mode.rawValue) }
        }
    }

    @Test func bypassEmitsOnlyTheDangerousFlag() {
        let tokens = SessionLaunchConfig(permissionMode: .bypass).claudeFlagTokens()
        #expect(tokens.contains("--dangerously-skip-permissions"))
        #expect(!tokens.contains("--permission-mode"))
        #expect(!tokens.contains("--allow-dangerously-skip-permissions"))
    }

    @Test func allowBypassArmsWithoutPermissionMode() {
        let tokens = SessionLaunchConfig(permissionMode: .allowBypass).claudeFlagTokens()
        #expect(tokens.contains("--allow-dangerously-skip-permissions"))
        #expect(!tokens.contains("--dangerously-skip-permissions"))
        #expect(!tokens.contains("--permission-mode"))
    }

    /// The load-bearing invariant: for EVERY mode, the dangerous flag and
    /// `--permission-mode` are never both present.
    @Test func neverEmitsBothBypassAndPermissionMode() {
        for mode in CCPermissionMode.allCases {
            let tokens = SessionLaunchConfig(
                permissionMode: mode,
                additionalDirectories: ["/tmp/a"],
                extraArgs: ["--verbose"]).claudeFlagTokens()
            let hasDangerous = tokens.contains("--dangerously-skip-permissions")
            let hasMode = tokens.contains("--permission-mode")
            #expect(!(hasDangerous && hasMode), "mode \(mode) emitted both flags")
        }
    }

    // MARK: Dirs / extra-args

    @Test func eachAdditionalDirectoryGetsItsOwnAddDir() {
        let tokens = SessionLaunchConfig(additionalDirectories: ["/a", "/b"]).claudeFlagTokens()
        #expect(tokens == ["--permission-mode", "auto", "--add-dir", "/a", "--add-dir", "/b"])
    }

    @Test func extraArgsPassThroughVerbatimAfterKnownFlags() {
        let tokens = SessionLaunchConfig(
            permissionMode: .standard,
            extraArgs: ["--foo", "bar baz"]).claudeFlagTokens()
        #expect(tokens == ["--foo", "bar baz"])
    }

    @Test func emptyExtraArgTokensAreDropped() {
        let tokens = SessionLaunchConfig(permissionMode: .standard,
                                         extraArgs: ["", "--x", ""]).claudeFlagTokens()
        #expect(tokens == ["--x"])
    }

    // MARK: Defaults / decoding

    @Test func safeDefaultIsAuto() {
        #expect(SessionLaunchConfig.safeDefault.permissionMode == .auto)
        #expect(SessionLaunchConfig.safeDefault.additionalDirectories.isEmpty)
    }

    /// A config JSON missing fields decodes to the safe defaults rather than
    /// failing the parent decode.
    @Test func partialJSONDecodesWithDefaults() throws {
        let data = Data("{}".utf8)
        let config = try JSONDecoder().decode(SessionLaunchConfig.self, from: data)
        #expect(config.permissionMode == .auto)
        #expect(config.additionalDirectories.isEmpty)
        #expect(config.extraArgs.isEmpty)
    }

    @Test func roundTripsThroughJSON() throws {
        let original = SessionLaunchConfig(permissionMode: .plan,
                                           additionalDirectories: ["/x"],
                                           extraArgs: ["--y"],
                                           remoteControl: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionLaunchConfig.self, from: data)
        #expect(decoded == original)
    }

    // MARK: Remote control

    /// New sessions are remote by default (CCorn's historical behavior); the
    /// flag is positional, so it is NOT one of the trailing flag tokens.
    @Test func remoteControlDefaultsTrueAndIsNotAFlagToken() {
        #expect(SessionLaunchConfig.safeDefault.remoteControl)
        #expect(SessionLaunchConfig().remoteControl)
        #expect(!SessionLaunchConfig(remoteControl: false).claudeFlagTokens().contains("--rc"))
        #expect(!SessionLaunchConfig(remoteControl: true).claudeFlagTokens().contains("--rc"))
    }

    /// A config JSON predating local sessions (no `remoteControl` key) decodes
    /// to remote — the posture every such session ran with.
    @Test func remoteControlMissingDecodesToTrue() throws {
        let config = try JSONDecoder().decode(SessionLaunchConfig.self, from: Data("{}".utf8))
        #expect(config.remoteControl)
    }

    // MARK: Base invocation (`--rc` placement)

    /// Remote new session: `--rc` carries the title; remote restart: `--rc`
    /// trails `--resume <uuid>`.
    @Test func remoteBaseIncludesRC() {
        #expect(SessionEngine.claudeBase(remoteControl: true, newTitle: "ccorn")
                == "claude --rc 'ccorn'")
        #expect(SessionEngine.claudeBase(remoteControl: true, resumeUUID: "abc")
                == "claude --resume 'abc' --rc")
    }

    /// Local session omits `--rc` entirely — no title handle on a new session,
    /// a plain `--resume` on a restart.
    @Test func localBaseOmitsRC() {
        #expect(SessionEngine.claudeBase(remoteControl: false, newTitle: "ccorn") == "claude")
        #expect(SessionEngine.claudeBase(remoteControl: false, resumeUUID: "abc")
                == "claude --resume 'abc'")
    }
}
