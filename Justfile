set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := true

mod_name := `bun -e 'console.log(JSON.parse(require("node:fs").readFileSync("info.json", "utf8")).name)'`
mod_version := `bun -e 'console.log(JSON.parse(require("node:fs").readFileSync("info.json", "utf8")).version)'`
package_dir := "pkg"
package_zip := package_dir + "/" + mod_name + "_" + mod_version + ".zip"
factorio_mods_dir := `if [ -n "${FACTORIO_MODS_DIR:-}" ]; then printf '%s' "$FACTORIO_MODS_DIR"; elif [ -d "$HOME/Library/Application Support/factorio/mods" ]; then printf '%s' "$HOME/Library/Application Support/factorio/mods"; elif [ -n "${APPDATA:-}" ] && [ -d "$APPDATA/Factorio/mods" ]; then printf '%s' "$APPDATA/Factorio/mods"; elif [ -d "$HOME/.factorio/mods" ]; then printf '%s' "$HOME/.factorio/mods"; elif [ -d "$HOME/.var/app/com.valvesoftware.Steam/.factorio/mods" ]; then printf '%s' "$HOME/.var/app/com.valvesoftware.Steam/.factorio/mods"; fi`

alias pkg := package
alias up := docker-up
alias down := docker-down

[private]
@help:
  just --list

# Install JavaScript dependencies.
deps:
  bun install

# Print resolved mod metadata and optional local install path.
info:
  @printf 'mod: %s\nversion: %s\npackage: %s\nFACTORIO_MODS_DIR: %s\n' '{{ mod_name }}' '{{ mod_version }}' '{{ package_zip }}' '{{ if factorio_mods_dir != "" { factorio_mods_dir } else { "<not found>" } }}'

# Build a release zip into pkg/.
package: _pkg-dir
  bun fmtk package --outdir {{ package_dir }}

# Symlink the repo into FACTORIO_MODS_DIR for live local testing.
install-link: _require_factorio_mods_dir
  @if [ -e "{{ factorio_mods_dir }}/{{ mod_name }}" ] && [ ! -L "{{ factorio_mods_dir }}/{{ mod_name }}" ]; then printf '%s\n' 'Refusing to replace a real directory at {{ factorio_mods_dir }}/{{ mod_name }}.' >&2; exit 1; fi
  @rm -f "{{ factorio_mods_dir }}"/{{ mod_name }}_*.zip
  @ln -sfn "$PWD" "{{ factorio_mods_dir }}/{{ mod_name }}"
  @printf 'linked %s -> %s\n' "{{ factorio_mods_dir }}/{{ mod_name }}" "$PWD"

# Package and copy the current zip into FACTORIO_MODS_DIR.
install-zip: package _require_factorio_mods_dir
  @rm -f "{{ factorio_mods_dir }}"/{{ mod_name }}_*.zip
  @cp "{{ package_zip }}" "{{ factorio_mods_dir }}/"
  @printf 'copied %s to %s\n' "{{ package_zip }}" "{{ factorio_mods_dir }}"

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

[private]
_pkg-dir:
  mkdir -p {{ package_dir }}

[private]
_require_factorio_mods_dir:
  @if [ -z "{{ factorio_mods_dir }}" ]; then printf '%s\n' 'Could not detect Factorio mods directory. Set FACTORIO_MODS_DIR to override.' >&2; exit 1; fi
  @if [ ! -d "{{ factorio_mods_dir }}" ]; then printf 'Directory not found: %s\n' "{{ factorio_mods_dir }}" >&2; exit 1; fi
