# GhostInTheWSL Release Process

This fork releases Windows assets through `.github/workflows/windows-release.yml`.
The upstream Ghostty release workflows are intentionally skipped on this fork
because they depend on upstream-only Namespace runner infrastructure.

## Prepare the Release

1. Make sure `main` is clean and current:

   ```sh
   git status --short --branch
   git pull --ff-only origin main
   ```

2. Bump the app version in `build.zig.zon`:

   ```sh
   ./scripts/prepare-release.sh <next-version>
   ```

   The release tag must match this value exactly. For example, tag `v0.1.3`
   requires:

   ```zig
   .version = "0.1.3",
   ```

3. Commit and push the version bump using the commands printed by the script:

   ```sh
   git add build.zig.zon
   git commit -m "build: bump version to v0.1.3"
   git push origin main
   ```

## Create the Release

Create an annotated tag for the same version and push it:

```sh
git tag -a v0.1.3 -m "v0.1.3"
git push origin v0.1.3
```

Pushing a `v*` tag starts the Windows Release workflow. That workflow builds
the bridge binaries, packages x64 and arm64 Windows artifacts, creates the
GitHub release, and attaches the `.exe` assets.

## Verify

Check the `Windows Release` workflow run for the tag:

<https://github.com/Codavo/ghostinthewsl/actions/workflows/windows-release.yml>

Expected workflow behavior on this fork:

- `Windows Release` runs for the tag.
- `Test` is skipped.
- upstream `Release Tag` is skipped.

After the workflow completes, verify the GitHub release has the portable and
setup `.exe` assets for both x64 and arm64.

## If a Tag Was Pushed Too Early

If the tag was pushed before the version bump, the build will fail with:

```text
tagged releases must be in vX.Y.Z format matching build.zig
```

Fix it by committing the version bump, moving the tag, and force-pushing only
the tag:

```sh
git tag -f -a v0.1.3 -m "v0.1.3" HEAD
git push --force origin v0.1.3
```

Do not force-push `main` for this case.
