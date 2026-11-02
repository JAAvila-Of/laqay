# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0](https://github.com/JAAvila-Of/laqay/releases/tag/v0.1.0) - 2026-11-02

### Added

- support native bitmap clipboard snapshots
- integrate native tray controls and per-user preferences
- add input-only diagnostics for remote sessions
- add passive input diagnostics to paste probe
- prepare bounded native Ctrl+V image paste experiment
- add safe file publication and native control diagnostics
- validate semantic focus in Explorer diagnostics
- add conservative clipboard policy and Explorer diagnostics

### Fixed

- detect empty startup entries and automate native validation ([#4](https://github.com/JAAvila-Of/laqay/pull/4))
- distinguish read-only values in folder focus checks
- recognize static text focus inside folder lists

### Other

- mark engineering releases as previews ([#16](https://github.com/JAAvila-Of/laqay/pull/16))
- validate portable release assets and checksums ([#14](https://github.com/JAAvila-Of/laqay/pull/14))
- validate Explorer recovery and pending clipboard exit ([#13](https://github.com/JAAvila-Of/laqay/pull/13))
- validate isolated RDP clipboard and Explorer paste ([#12](https://github.com/JAAvila-Of/laqay/pull/12))
- automate Explorer paste over an authenticated UNC share
- prepare paired private guests for network validation
- validate startup across real guest logons
- extend Explorer coverage for paths and write failures
- automate Explorer smoke checks inside the lab guest
- prepare a disposable Windows desktop lab
- establish public project governance ([#1](https://github.com/JAAvila-Of/laqay/pull/1))
- prepare bounded preference persistence checks
- verify single-instance tray launches with bounded runner
- record disabled and resumed paste validation
- record successful integrated screenshot paste trial
- record successful bounded tray control validation
- record successful reverse tab destination validation
- record first two-tab destination validation
- record isolated Explorer search validation
- record rename validation and pending search test
- record native text paste in Notepad and Explorer
- record successful native file paste regression
- record successful local console image paste trial
- record successful image pasting inside an RDP session
- record successful keyboard reception over RDP
- separate release preparation from publication
