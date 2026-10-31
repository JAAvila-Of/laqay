# Third-party components

Laqay's [MIT license](LICENSE) covers its original code, documentation, and icon
artwork. Dependencies retain their own copyright and license terms.

`Cargo.lock` identifies the resolved Cargo packages. The `windows` family uses
MIT OR Apache-2.0; the build-time `embed-resource` package uses MIT. Transitive
dependencies are checked as well. The current license policy permits MIT,
Apache-2.0, and Unicode-3.0. `unicode-ident` requires Unicode-3.0 in addition to
its MIT OR Apache-2.0 license. `deny.toml` is the authoritative allowlist;
exceptions or changes must be explicit and reviewed.

The dependency check covers known RustSec advisories, licenses, duplicate
versions, and allowed sources. It runs on changes and on a weekly schedule.
A passing check is not a guarantee that no vulnerability exists.

Release archives include the original license files for resolved Cargo packages
in `THIRD_PARTY_LICENSES.txt`, generated from the package sources used by the
build. This includes build and target-specific packages, even if their code is
not linked into the executable. It is an attribution inventory, not a statement
that each package runs at runtime. The Windows operating system and compiler
toolchain components have their own terms; this inventory concerns Cargo packages.

Keep these notices and the original license text when redistributing a build.
For modified distributions, also follow the identity guidance in
[TRADEMARKS.md](TRADEMARKS.md).
