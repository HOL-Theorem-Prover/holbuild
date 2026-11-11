# HBX archive registry

An HBX registry can be static HTTPS/object storage. GitHub Releases are enough
for a small registry: each release asset is immutable, downloadable by tag, and
can carry a JSON metadata sidecar plus checksum.

## Asset convention

Publish these files together:

```text
<TARGET>.hbx         # capsule produced by holbuild export
<TARGET>.hbx.json    # metadata sidecar produced by --metadata-out
<TARGET>.hbx.sha256  # sha256sum checksum file
```

The sidecar is for discovery before downloading the archive. Treat it as
advisory until the archive checksum has been verified; the archive carries its
own manifests (see below).

## Capsule layout

`holbuild export` writes the root package as a capsule: one tar with up to two
parts.

```text
holbuild-package/manifest   # holbuild-hbx-capsule-v1: name, version, toolchain_key, holbuild_version
holbuild-package/source/    # the package's source snapshot
holbuild-cache/             # holbuild-hbx-v2: cached build outputs of the package's theories
```

The snapshot is the package's `holproject.toml`, the sources it discovers (with
the committed manifest's own `exclude` and `exclude_globs`), and the files it
declares as inputs: action `extra_inputs`, `holbuild_extra_deps` of its
sources, generator inputs and shim manifests. It never holds `.git`,
`.holbuild`, `.holconfig.toml` or generator outputs; a consumer reruns
generators. Export fails on a symlink in the snapshot, a missing declared file
or a declared path outside the package root. Directory entries are 755 and
files 755 (executable) or 644, whatever the publisher's umask, so the archive's
bytes do not depend on the checkout beyond the snapshot's content. A package's
dependencies are not stored beside the snapshot; they are the declarations in
the snapshot's `holproject.toml`, and dependencies' capsules are never bundled.
The snapshot holds the files as committed, `holproject.toml` included, so a
dependency URL in it must not carry credentials.

A snapshot builds like the checkout it was taken from. Extracted into a
directory (`tar -xf F --strip-components=2 holbuild-package/source`), it gives
the same action keys as the checkout, so cache entries made from one restore
the other, and a dependency can point at the extracted directory with a
`.holconfig.toml` path override. Only declared files are in it: a script that
reads an undeclared file out of its action stage works in a checkout, which has
the file, and fails from the snapshot.

`toolchain_key` is the identity of the toolchain's theory-building semantics that
action keys carry. Cache entries in the capsule match only builds on the same
toolchain; on another toolchain holbuild builds from source.

| Command | Package part | Cache part |
|---|---|---|
| `export -o F [TARGET ...]` | yes | the root package's theories among the targets' closure |
| `export --closure -o F [TARGET ...]` | no | every theory in the targets' closure, dependencies included |
| `export --sources-only -o F` | yes | none; no targets, no theories built |

A target in another package is left out of the default export. An unbuilt
dependency theory fails only `--closure`.

`holbuild import F` imports the cache part only, and nothing from a capsule
without one.

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
  - name: Export capsule
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

A capsule's cache part holds only the package's own outputs, so a build after
`import` restores those and gets the dependencies' outputs from the cache or
builds them. Publish with `--closure` for an archive whose `import` and `build`
need nothing else.

Private repositories use normal GitHub authentication (`GH_TOKEN` or `gh auth
login`). Public repositories need no download token.

## Metadata sidecar

`holbuild export --metadata-out FILE` writes JSON like:

```json
{
  "format": "holbuild-hbx-metadata-v1",
  "archive_format": "holbuild-hbx-v2",
  "capsule_format": "holbuild-hbx-capsule-v1",
  "archive": "MyTheory.hbx",
  "sha256": "...",
  "size": "123456",
  "name": "mypackage",
  "version": "1.2.3",
  "toolchain_key": "...",
  "dependencies": [
    {"name": "hol", "git": "https://github.com/HOL-Theorem-Prover/HOL.git", "rev": "..."},
    {"name": "dep", "git": "https://github.com/example/dep.git", "rev": "..."}
  ],
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

`archive_format` is present when the archive has a cache part, `capsule_format`
when it has a package part; `version` when the package declares one.
`dependencies` copies the declarations in the package's manifest (`git` and
`rev`, or `from`, `path` and `manifest`). `targets` are the targets whose
theories the cache part holds. Repository URLs (`source_repo`, `hol_repo` and
dependencies' `git`) are written without any credentials that the URL carried.
