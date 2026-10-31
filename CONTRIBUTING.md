# Contributing to Laqay

Bug reports, questions, and proposals are welcome. Laqay is still in engineering
validation; discuss substantial changes in an issue before writing a patch.
Small, focused pull requests are welcome. Acceptance depends on the public
requirements and evidence, not on the amount of work already spent.

## Reports and proposals

Use the [issue forms](https://github.com/JAAvila-Of/laqay/issues/new/choose).
Search existing open and closed issues first. Describe a reproducible problem,
the expected behavior, the Windows build, the Laqay version or source commit,
and whether the session is local or remote. A tiny synthetic example is best.

Issues and attachments are public. Do not upload real clipboard contents,
private screenshots, credentials, personal paths, or unredacted diagnostic logs.
Diagnostics can include folder paths and process/session metadata. Reproduce
with disposable files and sanitize output. Report vulnerabilities privately
through [SECURITY.md](SECURITY.md).

## Development

Use stable Rust with the x86_64 MSVC toolchain, Visual Studio C++ Build Tools,
and the Windows SDK resource compiler. Start from the current `main` branch.
Keep application code, comments, documentation, issues, and pull requests in
English. The declared minimum Rust version is in `Cargo.toml`; discuss changes
to that requirement explicitly.

```sh
cargo fmt --all -- --check
cargo clippy --locked --all-targets --all-features -- -D warnings
cargo test --locked
cargo build --locked --release
```

These commands do not authorize a live keyboard or desktop test. Running the
application or a paste probe observes input and can create files. Agree on a
short test window and disposable destination first; verify hook removal and
process exit afterward. See the [integration matrix](docs/integration-tests.md).
State exactly which scenarios were tested and which remain pending.

Preserve ordinary file and text paste, editable-control exclusions, conservative
folder selection, non-overwriting publication, and clipboard privacy. Do not
add elevation, telemetry, a clipboard history, or another required paste shortcut
without first agreeing on a public change in scope.

## Commits and pull requests

Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/), with
English subjects: `fix: preserve native file paste`, for example. Supported
types are `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`,
`ci`, `chore`, and `revert`. Optional scopes and breaking-change `!` are allowed.
Subjects must be at most 100 characters. The same rule applies to the PR title
including the ` (#number)` suffix added by squash merging.

Keep each PR focused. Link the issue when there is one, explain observable
behavior, include relevant validation, and document limitations. All new branch
commits and the final squash title must pass the policy check. Use a PR into
`main`; do not force-push or delete that branch. Resolve review conversations
and pass the required checks before squash merging.

Do not change the package version, create release tags, or hand-author a release
changelog. [release-plz owns versioning](docs/RELEASING.md).

You retain copyright in your contribution. By submitting it, you confirm that
you have the right to contribute it under this repository's [MIT license](LICENSE).
No separate contributor agreement is required. Keep third-party copyright and
license notices intact, and identify dependencies or copied material in the PR.
The [dependency policy](THIRD_PARTY_NOTICES.md) is enforced by cargo-deny.

## Decisions and conduct

[GOVERNANCE.md](GOVERNANCE.md) describes maintainership and merge decisions.
The [code of conduct](CODE_OF_CONDUCT.md) applies to project interactions.
There is no guaranteed response time; maintainers may request a smaller change
or decline a proposal with an explanation.
