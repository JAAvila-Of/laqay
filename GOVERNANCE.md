# Project governance

Laqay is maintained by [Jóse Angel Avila (@JAAvila-Of)](https://github.com/JAAvila-Of).
The maintainer sets scope, reviews contributions, moderates project spaces,
and decides when a change is ready to merge or release. There is no separate
committee, voting process, or promised support schedule.

## Public decisions

Discuss proposals and substantial design changes in an issue. Decisions should
explain the user problem, resulting behavior, tradeoffs, and validation limits.
Contributors should be able to assess a proposal against the public documents.
The maintainer may request revisions, defer work, or decline it with a reason.

The current scope is an offline Windows utility that turns a clipboard image
into a non-overwriting PNG in the active physical Explorer folder using Ctrl+V.
Native file/text paste, conservative context selection, and clipboard privacy
are central requirements. Current limitations are recorded in the README and
[integration matrix](docs/integration-tests.md).

## Repository rules

- Changes to `main` go through pull requests and squash merges.
- The `windows`, `policy`, and `dependencies` checks must pass against an
  up-to-date branch.
- Review conversations must be resolved. No external approval is mandatory
  while the project has one maintainer; this does not waive review or checks.
- `main` cannot be force-pushed or deleted and keeps a linear history.
- Published `v*` tags cannot be updated or deleted. Create a new release to fix
  a released version; do not replace its tag or silently replace its assets.
- There is no standing ruleset bypass. Emergency changes to repository rules
  must be explicit and documented in the related issue or PR when safe.

Ruleset definitions are versioned in `.github/rulesets/`. Editing those files
does not apply settings automatically; a maintainer must apply and verify them
in GitHub. Security settings, labels, and merge settings are likewise repository
settings, not effects of committing documentation.

## Ownership and releases

`CODEOWNERS` routes review requests to the maintainer; it does not transfer
copyright. Contributions use the existing [MIT license](LICENSE).
[TRADEMARKS.md](TRADEMARKS.md) covers project identity.

release-plz manages all package versioning, changelogs, release PRs, tags, and
GitHub releases. The [release procedure](docs/RELEASING.md) separates CI artifacts,
engineering validation, and published releases. Automation does not approve or
merge its own release PR.
