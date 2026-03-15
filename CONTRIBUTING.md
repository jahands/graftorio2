# Contributing

## Prerequisites

- `bun` for project tooling and packaging
- `just` for common project commands
- Factorio installed locally for testing the mod
- Docker if you want to run the bundled Grafana/Prometheus stack

Install dependencies before starting development:

```sh
just deps
```

## Development workflow

For normal development:

1. Run `just deps` once after cloning or after dependency changes.
2. Run `just install-link` to link this repository into your local Factorio mods directory.
3. Start Factorio, load a save, and iterate on the mod in-place.
4. Re-run `just install-link` only if the symlink needs to be recreated.

When you need to verify the actual release artifact:

1. Run `just package` to build the zip in `pkg/`.
2. Run `just install-zip` if you want to test the packaged artifact exactly as Factorio will load it.
3. Start or reload Factorio and confirm the packaged mod behaves correctly.

When working on the Grafana/Prometheus side of the project:

1. Run `just docker-up` to start the local stack.
2. Use `just docker-logs` while debugging startup or scrape issues.
3. Run `just docker-down` when you are done.

If your Factorio mods directory is in a non-standard location, set `FACTORIO_MODS_DIR` before running install commands.

## Commit conventions

Releases are driven by conventional commit types configured in `.releaserc`.

- `feat` or `feature` -> minor release
- `fix`, `perf`, `compat`, `graphics`, `sound`, `locale`, `translate`, `control`, `balance`, `gui`, `other`, `info` -> patch release
- any breaking change -> major release

Examples:

```text
feat: add richer train metrics
fix: avoid writing invalid prometheus labels
compat: support Factorio 2.0.76 API change
```

## Release workflow

Releases are automated with GitHub Actions and `semantic-release`.

1. Merge conventional commits into the release branch.
2. On push, GitHub Actions runs the release workflow.
3. `semantic-release` determines the next version from commit history.
4. The release job updates `info.json` and `changelog.txt`, builds the mod zip, creates a GitHub release, and uploads the package to the Factorio mod portal.

Current repo configuration notes:

- Release automation is configured for pushes to `main` in `.github/workflows/release.yml`.
- `semantic-release` is also configured to release from `main` in `.releaserc`.
- The workflow requires `FACTORIO_TOKEN` to be configured in GitHub Actions secrets.

## Manual pre-release checks

Before merging release-worthy changes, it is useful to:

1. Run `just package`.
2. Optionally run `just install-zip` and verify the packaged mod in Factorio.
3. Make sure your commit messages follow the release conventions above.
