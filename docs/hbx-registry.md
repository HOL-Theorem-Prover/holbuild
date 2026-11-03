# HBX archive registry

An HBX registry can be static HTTPS/object storage. GitHub Releases are enough
for a small registry: each release asset is immutable, downloadable by tag, and
can carry a JSON metadata sidecar plus checksum.

## Asset convention

Publish these files together:

```text
<TARGET>.hbx         # archive produced by holbuild export
<TARGET>.hbx.json    # metadata sidecar produced by --metadata-out
<TARGET>.hbx.sha256  # sha256sum checksum file
```

The sidecar is for discovery before downloading the archive. Treat it as
advisory until the archive checksum has been verified; the archive still carries
its internal `holbuild-cache/manifest`.

HBX archives are trusted build inputs, not sandboxed packages. Their cached
Poly/ML outputs may be loaded by a later build. Import only from a trusted
publisher; a checksum detects corruption but does not authenticate who produced
the archive.

## Publishing with GitHub Releases

Example release job fragment:

```yaml
permissions:
  contents: write

steps:
  - uses: actions/checkout@v4
  - name: Build target
    run: holbuild build MyTheory
  - name: Export HBX archive
    run: |
      holbuild export \
        -o MyTheory.hbx \
        --metadata-out MyTheory.hbx.json \
        MyTheory
      sha256sum MyTheory.hbx > MyTheory.hbx.sha256
  - name: Upload release assets
    env:
      GH_TOKEN: ${{ github.token }}
    run: |
      gh release upload "$GITHUB_REF_NAME" \
        MyTheory.hbx \
        MyTheory.hbx.json \
        MyTheory.hbx.sha256 \
        --clobber
```

For a release created outside the workflow, replace `$GITHUB_REF_NAME` with the
release tag.

## Consuming from GitHub Releases

```sh
gh release download v1.2.3 \
  -p 'MyTheory.hbx' \
  -p 'MyTheory.hbx.json' \
  -p 'MyTheory.hbx.sha256'
sha256sum -c MyTheory.hbx.sha256
holbuild import MyTheory.hbx
holbuild build MyTheory
```

Private repositories use normal GitHub authentication (`GH_TOKEN` or `gh auth
login`). Public repositories need no download token.

## Metadata sidecar

`holbuild export --metadata-out FILE` writes JSON like:

```json
{
  "format": "holbuild-hbx-metadata-v1",
  "archive_format": "holbuild-hbx-v1",
  "archive": "MyTheory.hbx",
  "sha256": "...",
  "size": "123456",
  "targets": ["MyTheory"],
  "action_count": 1,
  "holbuild_version": "0.8.1",
  "created_at": "2026-06-27T00:00:00Z",
  "source_repo": "https://github.com/example/project.git",
  "source_rev": "...",
  "hol_repo": "https://github.com/HOL-Theorem-Prover/HOL.git",
  "hol_rev": "..."
}
```
