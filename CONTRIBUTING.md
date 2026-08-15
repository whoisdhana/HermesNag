# Contributing

- `make check` runs all three suites (server pytest, Swift, MCP protocol);
  the pre-push hook enforces it (`git config core.hooksPath .githooks`).
- No sleeps in tests — inject the clock. Any test over 2 s is a design smell.
- Store UTC only; naive datetimes are rejected, never guessed.
- The Mac app builds with **Command Line Tools alone** (SwiftPM, swift-testing).
  No Xcode or XcodeGen. See mac/Makefile for the rpath gotchas.
- Run what you write: PRs should show real output, not claims.
