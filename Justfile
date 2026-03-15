set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := true

mod_name := `bun -e 'console.log(JSON.parse(require("node:fs").readFileSync("info.json", "utf8")).name)'`
mod_version := `bun -e 'console.log(JSON.parse(require("node:fs").readFileSync("info.json", "utf8")).version)'`
package_dir := "pkg"
package_zip := package_dir + "/" + mod_name + "_" + mod_version + ".zip"

alias pkg := package
alias up := docker-up
alias down := docker-down

# Show available recipes.
help:
  @just --list

# Install JavaScript dependencies.
deps:
  bun install

# Print resolved mod metadata and optional local install path.
info:
  @printf 'mod: %s\nversion: %s\npackage: %s\nFACTORIO_MODS_DIR: %s\n' '{{ mod_name }}' '{{ mod_version }}' '{{ package_zip }}' "${FACTORIO_MODS_DIR:-<unset>}"

# Datestamp the current changelog entry.
datestamp:
  @_fmtk "datestamp"

# Bump the mod version using FMTK.
version:
  @_fmtk "version"

# Build a release zip into pkg/.
package: _pkg-dir
  @_fmtk "package" "--outdir" package_dir

# Symlink the repo into FACTORIO_MODS_DIR for live local testing.
install-link: _require_factorio_mods_dir
  @if [ -e "$FACTORIO_MODS_DIR/{{ mod_name }}" ] && [ ! -L "$FACTORIO_MODS_DIR/{{ mod_name }}" ]; then printf '%s\n' 'Refusing to replace a real directory at $FACTORIO_MODS_DIR/{{ mod_name }}.' >&2; exit 1; fi
  @rm -f "$FACTORIO_MODS_DIR"/{{ mod_name }}_*.zip
  @ln -sfn "$PWD" "$FACTORIO_MODS_DIR/{{ mod_name }}"
  @printf 'linked %s -> %s\n' "$FACTORIO_MODS_DIR/{{ mod_name }}" "$PWD"

# Package and copy the current zip into FACTORIO_MODS_DIR.
install-zip: package _require_factorio_mods_dir
  @rm -f "$FACTORIO_MODS_DIR"/{{ mod_name }}_*.zip
  @cp "{{ package_zip }}" "$FACTORIO_MODS_DIR/"
  @printf 'copied %s to %s\n' "{{ package_zip }}" "$FACTORIO_MODS_DIR"

# Start the local Grafana/Prometheus stack.
docker-up:
  docker compose up -d

# Stop the local Grafana/Prometheus stack.
docker-down:
  docker compose down

# Follow stack logs, optionally filtered by service.
docker-logs service="":
  @if [ -n "{{ service }}" ]; then docker compose logs -f "{{ service }}"; else docker compose logs -f; fi

# Remove generated zip artifacts.
clean:
  rm -f {{ package_dir }}/*.zip

# ================================= #
# ============ Helpers ============ #
# ================================= #

[private]
[positional-arguments]
_fmtk +args:
  bun fmtk "$@"

[private]
_pkg-dir:
  mkdir -p {{ package_dir }}

[private]
_require_factorio_mods_dir:
  @if [ -z "${FACTORIO_MODS_DIR:-}" ]; then printf '%s\n' 'Set FACTORIO_MODS_DIR or put it in a .env file.' >&2; exit 1; fi
  @if [ ! -d "$FACTORIO_MODS_DIR" ]; then printf 'Directory not found: %s\n' "$FACTORIO_MODS_DIR" >&2; exit 1; fi
