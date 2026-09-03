# Changelog

All notable changes to `managoat_runner` are documented here. Format:
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/). Pre-1.0, a minor bump (`0.x` to `0.y`) may
include breaking changes and says so; patch releases are always safe to take.

Merging a version bump to `main` publishes it to hex; a PR that changes what
the package ships without a bump fails the release gate.

## [Unreleased]

## [0.2.1] - 2026-09-03

### Changed

- Raised the test coverage gate from 85% to 97% after adding behavioral
  coverage for connection failure classification, malformed daemon replies,
  stream decoding, subscription cleanup, and the fake daemon's stderr and
  missing-session contracts.

## [0.2.0] - 2026-09-03

### Changed

- Takes `managoat_sandbox ~> 0.2.0`, where a command stream that closes
  without an exit frame is `{:error, %{ref: ref}, :closed_before_exit}`
  rather than a synthesised `{:exit, %{ref: ref}, 0}`
  (managoat/managoat_sandbox#4).
- `Managoat.Runner.Connection` needed no change: a subscriber whose command
  loses its exit already gets `{:error, %{ref: ref}, :runner_disconnected}`,
  because the protocol has no way for a session to end without a code — the
  daemon watches the process and reports what it exits with. The only route
  to a missing exit is the connection going away.
- `Managoat.Runner.FakeDaemon`'s `drop` instruction says that instead of
  faking it. It used to emit an exit frame with code 0; it now stops the
  socket, so the subscriber gets the disconnect the real protocol would
  give. A script that uses `drop` is the last thing that daemon does.

## [0.1.0] - 2026-09-02

### Added

- Extracted from Fountain (BinaryBourbon/fountain#1381).
