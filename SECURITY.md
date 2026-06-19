# Security Policy

## Reporting a vulnerability

Please report security vulnerabilities privately, not through public issues.

Use GitHub's private vulnerability reporting: open the **Security** tab of this
repository and click **Report a vulnerability**. That creates a private advisory
visible only to you and the maintainer.

Expect an initial acknowledgement within a few days. CCorn is maintained by one
person, so please allow reasonable time for a fix before any public disclosure.

## Scope

CCorn is a native macOS app that manages Claude Code sessions in tmux. By design
it runs **without the App Sandbox**: it spawns `tmux`, `claude`, and helpers like
`ps`, `lsof`, and `osascript`, watches directories with FSEvents, and sends
AppleEvents to Terminal. Reports that are especially welcome:

- Command or argument injection into the tmux or `claude` invocations.
- Privilege, path, or process-targeting issues arising from the unsandboxed surface.
- Leakage of session data, tokens, or local paths.
- Signature, notarization, or update-integrity weaknesses in the release artifact.

Vulnerabilities in Claude Code itself (the CLI) or in tmux belong to those
projects, not here.

## Supported versions

Only the most recent released version receives security fixes.
