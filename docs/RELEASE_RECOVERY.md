# Bounded v0.1.1 delivery recovery

The initial v0.1.1 delivery stopped at draft discovery: the REST by-tag endpoint
returns published releases, not drafts. No release asset was uploaded or
published. Release-plz had already created the correct tag and draft. Neither
the version nor the tag may be moved or reused to hide this failure.

`Recover v0.1.1 delivery` is a one-time workflow restricted to main and:

- Tag `v0.1.1`, application commit `d0b0c24e1892878db3095d24a57ca52894d29988`.
- Existing release-plz draft ID `431972518`, still empty and a pre-release.
- A separate control checkout at the reviewed recovery workflow commit.
- The same administrative immutability preflight as ordinary publication.

It verifies clean tracked source/control checkouts and Cargo's package/version,
builds only the tagged application with its original locked build arguments,
and retains the resulting files before attempting publication. It does not
create a version, tag, or release. The fixed finalizer discovers the existing
draft by ID and retains all ordinary download, asset, immutability, and release
attestation checks. Published releases and populated drafts remain refused.

## Two distinct commits

In ordinary releases, the application source and workflow commit are identical.
During this recovery, GitHub's OIDC certificate identifies the newer recovery
workflow commit. It must not be described as the older application commit.

The workflow generates two signed attestations for each delivery file:

1. Standard build provenance identifying the reviewed recovery builder.
2. A custom source binding with predicate type
   `https://github.com/JAAvila-Of/laqay/attestations/release-source/v1`.

The source binding has exactly these fields:

```json
{
  "repository": "JAAvila-Of/laqay",
  "tag": "v0.1.1",
  "sourceCommit": "d0b0c24e1892878db3095d24a57ca52894d29988",
  "builderCommit": "FULL_REVIEWED_RECOVERY_WORKFLOW_COMMIT"
}
```

The trusted workflow derives the binding from its checked-out Git commits and
checks them before building and again before signing. These are workflow claims
covered by the signature, not extra facts independently certified by GitHub.
Review the recovery workflow and trust its exact commit before accepting them.
This does not claim a higher SLSA level or add a Windows publisher signature.

## Verify a recovered download

Use the full reviewed recovery workflow commit as `$builderCommit`, not the
application tag's commit. First verify GitHub's immutable release and asset:

```powershell
gh release verify v0.1.1 --repo JAAvila-Of/laqay
gh release verify-asset v0.1.1 .\laqay-windows-x86_64.zip --repo JAAvila-Of/laqay
$builderCommit = 'FULL_REVIEWED_RECOVERY_WORKFLOW_COMMIT'
gh attestation verify .\laqay-windows-x86_64.zip --repo JAAvila-Of/laqay --signer-workflow JAAvila-Of/laqay/.github/workflows/recover-release.yml --source-digest $builderCommit --source-ref refs/heads/main --deny-self-hosted-runners
$binding = gh attestation verify .\laqay-windows-x86_64.zip --repo JAAvila-Of/laqay --signer-workflow JAAvila-Of/laqay/.github/workflows/recover-release.yml --source-digest $builderCommit --source-ref refs/heads/main --deny-self-hosted-runners --predicate-type https://github.com/JAAvila-Of/laqay/attestations/release-source/v1 --format json
if ($LASTEXITCODE -ne 0) { throw 'Source-binding signature verification failed.' }
```

Parse that verified JSON and require an exact match of all four predicate fields
above, including the expected builder commit. Merely finding the repository name
or accepting any signed predicate is insufficient. The finalizer's
`check_source_binding` implements this exact comparison after cryptographic
verification. Repeat the asset and both attestation checks for `laqay.exe` and
`SHA256SUMS.txt`; compare the package checksums as usual.

The failed original run remains part of the release history. A successful
recovery is a separate run and does not turn that failed run green. The next
ordinary release must exercise the corrected normal publication path as well.
