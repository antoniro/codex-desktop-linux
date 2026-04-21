#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_NAME="codex-desktop"
DISTRO=""
FRESH_INSTALL=0
PROVIDED_DMG_PATH=""

info()  { echo "[INFO] $*" >&2; }
warn()  { echo "[WARN] $*" >&2; }
error() { echo "[ERROR] $*" >&2; exit 1; }

usage() {
    cat <<'HELP'
Usage: bash scripts/install-native.sh [OPTIONS] [path/to/Codex.dmg]

Builds and installs Codex Desktop as a native package for the current distro.

Options:
  --fresh   Rebuild from scratch and refresh the cached DMG
  -h, --help
            Show this help message and exit

If no DMG path is provided, install.sh downloads Codex.dmg automatically or
reuses the cached copy in the repo root.
HELP
}

detect_distro() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf5 >/dev/null 2>&1; then
        echo "dnf5"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    else
        echo "unknown"
    fi
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

refresh_user_tool_paths() {
    local dir
    for dir in "$HOME/.local/bin" "$HOME/.cargo/bin"; do
        if [ -d "$dir" ] && ! printf '%s\n' "$PATH" | tr ':' '\n' | grep -Fxq "$dir"; then
            PATH="$dir:$PATH"
        fi
    done
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

build_package() {
    case "$DISTRO" in
        apt)
            info "Building Debian package"
            "$REPO_DIR/scripts/build-deb.sh"
            ;;
        dnf5|dnf)
            info "Building RPM package"
            "$REPO_DIR/scripts/build-rpm.sh"
            ;;
        pacman)
            info "Building pacman package"
            "$REPO_DIR/scripts/build-pacman.sh"
            ;;
        *)
            error "Unsupported package manager. Build the package manually for this distro."
            ;;
    esac
}

latest_dist_artifact() {
    local pattern="$1"
    local artifact

    artifact="$(find "$REPO_DIR/dist" -maxdepth 1 -type f -name "$pattern" | sort -V | tail -n 1)"
    [ -n "$artifact" ] || error "No package artifact found for pattern: $pattern"
    echo "$artifact"
}

install_package() {
    local artifact=""

    case "$DISTRO" in
        apt)
            artifact="$(latest_dist_artifact "${PACKAGE_NAME}_*.deb")"
            info "Installing package: $artifact"
            sudo apt install -y "$artifact"
            ;;
        dnf5)
            artifact="$(latest_dist_artifact "${PACKAGE_NAME}-*.rpm")"
            info "Installing package: $artifact"
            sudo dnf5 install -y "$artifact"
            ;;
        dnf)
            artifact="$(latest_dist_artifact "${PACKAGE_NAME}-*.rpm")"
            info "Installing package: $artifact"
            sudo dnf install -y "$artifact"
            ;;
        pacman)
            artifact="$(latest_dist_artifact "${PACKAGE_NAME}-*.pkg.tar.*")"
            info "Installing package: $artifact"
            sudo pacman -U --noconfirm "$artifact"
            ;;
        *)
            error "Unsupported package manager. Install the built package manually from dist/."
            ;;
    esac
}

enable_update_service() {
    if ! command -v systemctl >/dev/null 2>&1; then
        warn "systemctl not found; skipping codex-update-manager.service enablement"
        return 0
    fi

    info "Enabling codex-update-manager.service for the current user"
    if ! systemctl --user daemon-reload; then
        warn "Failed to reload the user systemd manager"
        return 0
    fi

    if ! systemctl --user enable --now codex-update-manager.service; then
        warn "Failed to enable or start codex-update-manager.service automatically"
        warn "You can retry manually with: systemctl --user enable --now codex-update-manager.service"
    fi
}

main() {
    parse_args "$@"
    DISTRO="$(detect_distro)"
    [ "$DISTRO" != "unknown" ] || error "Unsupported package manager. Install dependencies manually and build a package yourself."

    refresh_user_tool_paths
    "$REPO_DIR/scripts/install-deps.sh"
    refresh_user_tool_paths

    ensure_codex_cli
    build_app
    build_package
    install_package
    enable_update_service

    info "Native install complete. Launch with: codex-desktop"
}

main "$@"
