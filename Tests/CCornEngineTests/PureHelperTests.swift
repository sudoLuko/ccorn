import Foundation
import Testing

/// Pure helpers: path canonicalization + watch-dir/cwd matching (with a real
/// `/tmp` symlink), window-name sanitization, and aggregate-dot severity ordering.
@Suite struct PureHelperTests {

    // MARK: Path canonicalization + watch-dir matching

    @Test func canonicalizeConvergesSymlinkedTempForms() {
        // /tmp is a symlink to /private/tmp. The two spellings MUST canonicalize to
        // the same path so a watch dir written one way matches a cwd written the
        // other. Foundation normalizes toward the shorter `/tmp` form.
        #expect(SessionDiscovery.canonicalize("/tmp") == SessionDiscovery.canonicalize("/private/tmp"))
        #expect(SessionDiscovery.canonicalize("/private/tmp") == "/tmp")
    }

    /// RUNTIME_FINDINGS T3 fix: Foundation strips `/private` only when the leaf
    /// exists, which made canonicalization existence-dependent — a deleted (or
    /// never-created) project dir under one spelling silently stopped matching
    /// the other. Both spellings must converge for missing paths too.
    @Test func canonicalizeIsExistenceIndependent() {
        let missing = "ccorn-definitely-missing-\(UUID().uuidString)"
        #expect(SessionDiscovery.canonicalize("/private/tmp/\(missing)") == "/tmp/\(missing)")
        #expect(SessionDiscovery.canonicalize("/private/tmp/\(missing)")
                == SessionDiscovery.canonicalize("/tmp/\(missing)"))
        #expect(SessionDiscovery.canonicalize("/private/var/\(missing)")
                == "/var/\(missing)")
        // Paths not under the /private firmlinks are untouched.
        #expect(SessionDiscovery.canonicalize("/Users/nobody/\(missing)") == "/Users/nobody/\(missing)")
        #expect(SessionDiscovery.canonicalize("/privateer/\(missing)") == "/privateer/\(missing)")
    }

    @Test func expandTildeExpandsHome() {
        #expect(SessionDiscovery.expandTilde("~/dev") == NSHomeDirectory() + "/dev")
    }

    @Test func isPathInsideIsComponentAware() {
        #expect(SessionDiscovery.isPath("/a/b/c", inside: "/a/b"))
        #expect(SessionDiscovery.isPath("/a/b", inside: "/a/b"))      // equal counts as inside
        #expect(!SessionDiscovery.isPath("/a/bc", inside: "/a/b"))    // sibling prefix, NOT inside
        #expect(!SessionDiscovery.isPath("/a", inside: "/a/b"))       // parent, NOT inside
    }

    @Test func symlinkedWatchDirMatchesResolvedCwd() {
        // A cwd reported under the /private/tmp spelling is matched by a watch dir
        // given as the /tmp symlink, once both are canonicalized.
        let watch = SessionDiscovery.canonicalize("/tmp")
        let cwd = SessionDiscovery.canonicalize("/private/tmp")
        #expect(SessionDiscovery.isPath(cwd, inside: watch))         // converge -> equal -> inside
    }

    // MARK: Window-name sanitization

    @Test func sanitizeReplacesTmuxSignificantChars() {
        #expect(TmuxController.sanitize("mella.studio") == "mella-studio") // dot breaks target syntax
        #expect(TmuxController.sanitize("my project") == "my-project")     // space breaks target
        #expect(TmuxController.sanitize("ccorn:probe") == "ccorn-probe")   // colon is the session sep
    }

    @Test func sanitizeCollapsesRunsAndTrimsEdges() {
        #expect(TmuxController.sanitize("a..b") == "a-b")        // runs collapse to a single -
        #expect(TmuxController.sanitize("-edge-") == "edge")     // leading/trailing - trimmed
        #expect(TmuxController.sanitize("keep_under-score") == "keep_under-score") // _ and - kept
    }

    @Test func sanitizeFallsBackForEmptyResult() {
        #expect(TmuxController.sanitize("...") == "session")
        #expect(TmuxController.sanitize("") == "session")
    }

    // MARK: Shell single-quoting for send-keys payloads (injection defense)

    @Test func shellQuoteNeutralizesShellExpansion() {
        // The quoted result is what the pane's interactive shell receives. Single
        // quotes make command substitution, backticks, and parameter expansion
        // inert — so a crafted title/uuid cannot execute commands at session start.
        #expect(TmuxController.shellQuote("plain") == "'plain'")
        #expect(TmuxController.shellQuote("My Project") == "'My Project'")
        #expect(TmuxController.shellQuote("$(rm -rf ~)") == "'$(rm -rf ~)'")
        #expect(TmuxController.shellQuote("a`whoami`b") == "'a`whoami`b'")
        #expect(TmuxController.shellQuote("$HOME") == "'$HOME'")
        // A double quote is harmless inside single quotes (no special-casing).
        #expect(TmuxController.shellQuote("a\"b") == "'a\"b'")
    }

    @Test func shellQuoteEscapesEmbeddedSingleQuotes() {
        // A literal single quote is closed, escaped, and reopened: '\''
        #expect(TmuxController.shellQuote("it's") == "'it'\\''s'")
        #expect(TmuxController.shellQuote("'") == "''\\'''")
    }

    // MARK: Aggregate-mark severity ordering

    @Test func aggregatePicksWorstPresentation() {
        // Full ladder: crashed > needsAuth > noRemote > waiting > stale >
        // working > running (broken tier on top).
        #expect(StatusPresentation.aggregate(
            [.running, .working, .stale, .waiting, .noRemote, .needsAuth, .crashed]) == .crashed)
        #expect(StatusPresentation.aggregate(
            [.running, .working, .stale, .waiting, .noRemote, .needsAuth]) == .needsAuth)
        #expect(StatusPresentation.aggregate(
            [.running, .working, .stale, .waiting, .noRemote]) == .noRemote)
        // Waiting outranks Stale (a waiting session is blocked on the user).
        #expect(StatusPresentation.aggregate([.running, .working, .stale, .waiting]) == .waiting)
        #expect(StatusPresentation.aggregate([.running, .working, .stale]) == .stale)
        #expect(StatusPresentation.aggregate([.running, .working]) == .working)
        #expect(StatusPresentation.aggregate([.running, .running]) == .running)
    }

    @Test func aggregateIgnoresNonActiveStates() {
        // No active color -> nil (caller shows the empty/outline dot).
        #expect(StatusPresentation.aggregate([.stopped, .unmanaged]) == nil)
        #expect(StatusPresentation.aggregate([]) == nil)
        // Non-active states don't dilute the worst active one.
        #expect(StatusPresentation.aggregate([.stopped, .unmanaged, .running]) == .running)
    }
}
