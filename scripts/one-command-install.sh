#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FRESH_INSTALL=0
PROVIDED_DMG_PATH=""

info()  { echo "[INFO] $*" >&2; }
warn()  { echo "[WARN] $*" >&2; }
error() { echo "[ERROR] $*" >&2; exit 1; }

usage() {
    cat <<'HELP'
Usage: bash scripts/one-command-install.sh [OPTIONS] [path/to/Codex.dmg]

Installs Codex Desktop as a native package for the current distro.

Options:
  --fresh   Rebuild from scratch and refresh the cached DMG
  -h, --help
            Show this help message and exit

If no DMG path is provided, install.sh downloads Codex.dmg automatically or
reuses the cached copy in the repo root.
HELP
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --fresh)
                FRESH_INSTALL=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                error "Unknown option: $1 (see --help)"
                ;;
            *)
                [ -z "$PROVIDED_DMG_PATH" ] || error "Only one DMG path may be provided"
                PROVIDED_DMG_PATH="$1"
                ;;
        esac
        shift
    done
}

path_has_dir() {
    local needle="$1"
    printf '%s\n' "$PATH" | tr ':' '\n' | grep -Fxq "$needle"
}

prepend_path_if_present() {
    local dir="$1"
    if [ -d "$dir" ] && ! path_has_dir "$dir"; then
        PATH="$dir:$PATH"
    fi
}

refresh_user_tool_paths() {
    local node_dir

    prepend_path_if_present "$HOME/.local/bin"
    prepend_path_if_present "$HOME/.cargo/bin"

    if [ -d "$HOME/.nvm/versions/node" ]; then
        while IFS= read -r node_dir; do
            prepend_path_if_present "$node_dir/bin"
        done < <(find "$HOME/.nvm/versions/node" -mindepth 1 -maxdepth 1 -type d | sort -Vr)
    fi

    export PATH
}

ensure_codex_cli() {
    local package_spec="${CODEX_CLI_NPM_SPEC:-@openai/codex}"

    refresh_user_tool_paths
    if command -v codex >/dev/null 2>&1; then
        info "Using Codex CLI: $(command -v codex)"
        return 0
    fi

    info "Installing Codex CLI package ${package_spec}"
    if npm install -g "$package_spec"; then
        :
    else
        warn "Global npm install failed; retrying with ~/.local prefix"
        npm install -g --prefix "$HOME/.local" "$package_spec"
    fi

    refresh_user_tool_paths
    command -v codex >/dev/null 2>&1 || error "Codex CLI install completed but 'codex' is still not on PATH"
    info "Using Codex CLI: $(command -v codex)"
}

build_app() {
    local install_args=()

    if [ "$FRESH_INSTALL" -eq 1 ]; then
        install_args+=(--fresh)
    fi
    if [ -n "$PROVIDED_DMG_PATH" ]; then
        install_args+=("$PROVIDED_DMG_PATH")
    fi

    info "Generating Linux app bundle"
    "$REPO_DIR/install.sh" "${install_args[@]}"
}

main() {
    parse_args "$@"
    cd "$REPO_DIR"

    refresh_user_tool_paths
    "$REPO_DIR/scripts/install-deps.sh"
    refresh_user_tool_paths

    ensure_codex_cli
    build_app

    info "Building native package for this distro"
    make -C "$REPO_DIR" package

    info "Installing native package"
    make -C "$REPO_DIR" install

    info "Enabling codex-update-manager.service for the current user"
    if ! make -C "$REPO_DIR" service-enable; then
        warn "Could not enable the updater service automatically."
        warn "You can retry manually with: make service-enable"
    fi

    info "One-command install complete. Launch with: codex-desktop"
}

main "$@"
