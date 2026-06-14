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

    /// runtime findings T3 fix: Foundation strips `/private` only when the leaf
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

    // MARK: AppleScript string-literal quoting (Open in Terminal custom title)

    @Test func appleScriptQuoteWrapsAndPassesPlainText() {
        // A plain title becomes a quoted AppleScript string literal, set verbatim
        // as the Terminal tab's custom title.
        #expect(TmuxController.appleScriptQuote("auth refactor") == "\"auth refactor\"")
        // The title is a custom title, never `do script`, and AppleScript does no
        // shell expansion — so injection-shaped names are inert and pass through.
        #expect(TmuxController.appleScriptQuote("$(rm -rf ~)") == "\"$(rm -rf ~)\"")
    }

    @Test func appleScriptQuoteEscapesQuotesAndBackslashes() {
        let bs = "\\"   // a single backslash
        let dq = "\""   // a single double quote
        // A double quote would otherwise terminate the literal early.
        #expect(TmuxController.appleScriptQuote("a" + dq + "b") == dq + "a" + bs + dq + "b" + dq)
        // A backslash is doubled.
        #expect(TmuxController.appleScriptQuote("a" + bs + "b") == dq + "a" + bs + bs + "b" + dq)
        // Backslash is escaped BEFORE the quote, so \" → \\\" (escaped backslash
        // then escaped quote), never \\" (escaped backslash + a stray terminator).
        #expect(TmuxController.appleScriptQuote(bs + dq) == dq + bs + bs + bs + dq + dq)
    }

    // MARK: Per-client view-session naming (Open in Terminal isolation)

    @Test func viewSessionNameDerivesFromWindowId() {
        // The `@` is stripped so the name is a tmux-safe session token that
        // still reads back to its window in `tmux ls`.
        #expect(TmuxController.uniqueViewSessionName(forWindowId: "@22", taken: [])
                == "ccorn-view-22")
    }

    @Test func viewSessionNameDisambiguatesOnCollision() {
        // Two terminals attached to the same window get distinct view sessions
        // (a second `new-session -s <name>` would otherwise fail as a dup).
        let taken: Set<String> = ["ccorn-view-22"]
        #expect(TmuxController.uniqueViewSessionName(forWindowId: "@22", taken: taken)
                == "ccorn-view-22-2")
        #expect(TmuxController.uniqueViewSessionName(forWindowId: "@22",
                                                     taken: taken.union(["ccorn-view-22-2"]))
                == "ccorn-view-22-3")
    }

    @Test func matchViewClientFindsAttachedViewTTY() {
        // A live client on this window's view → its tty (raise that terminal).
        let lines = "ccorn-view-3\t/dev/ttys017\nccorn\t/dev/ttys004"
        #expect(TmuxController.matchViewClient(windowId: "@3", clientLines: lines)
                == "/dev/ttys017")
    }

    @Test func matchViewClientMatchesCollisionSuffix() {
        // A second terminal on the same window lands on `-2`; still this session.
        let lines = "ccorn-view-3-2\t/dev/ttys020"
        #expect(TmuxController.matchViewClient(windowId: "@3", clientLines: lines)
                == "/dev/ttys020")
    }

    @Test func matchViewClientDoesNotBleedAcrossWindowIds() {
        // @1's base `ccorn-view-1` must not match @10's `ccorn-view-10`; the `-`
        // separator before the collision number is what keeps them distinct.
        let lines = "ccorn-view-10\t/dev/ttys099"
        #expect(TmuxController.matchViewClient(windowId: "@1", clientLines: lines) == nil)
    }

    @Test func matchViewClientNilWhenNoViewAttached() {
        // No view client (closed terminal / only the managed session) → open fresh.
        #expect(TmuxController.matchViewClient(windowId: "@3",
                                               clientLines: "ccorn\t/dev/ttys004") == nil)
        #expect(TmuxController.matchViewClient(windowId: "@3", clientLines: "") == nil)
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
