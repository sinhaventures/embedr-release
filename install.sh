#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="sinhaventures"
REPO_NAME="embedr-release"
REPO="$REPO_OWNER/$REPO_NAME"
GITHUB_API="https://api.github.com/repos/$REPO"
GITHUB_RELEASES="https://github.com/$REPO/releases"
INSTALLER_BASE="${EMBEDR_INSTALLER_BASE_URL:-https://get.embedr.app}"
INSTALLER_BASE="${INSTALLER_BASE%/}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

headline() {
    printf '\n%b\n' "${CYAN}Embedr installer${NC}"
}

info() {
    printf '%b\n' "${CYAN}[INFO]${NC} $*"
}

success() {
    printf '%b\n' "${GREEN}[OK]${NC} $*"
}

warn() {
    printf '%b\n' "${YELLOW}[WARN]${NC} $*"
}

error() {
    printf '%b\n' "${RED}[ERROR]${NC} $*"
    exit 1
}

usage() {
    cat <<EOF
Embedr desktop installer

Usage:
  curl -fsSL $INSTALLER_BASE | bash
  curl -fsSL $INSTALLER_BASE/install.sh | bash
  curl -fsSL $INSTALLER_BASE/install.sh | bash -s -- --version v0.2.1

Options:
  --version VERSION   Install a specific release tag or version
  --help              Show this help message

If you do not pass --version, the latest release is installed.
EOF
}

ORIGINAL_ARGS=("$@")
for arg in "$@"; do
    case "$arg" in
        --help|-h)
            usage
            exit 0
            ;;
    esac
done

OS="$(uname -s)"
ARCH_RAW="$(uname -m)"
case "$OS" in
    Darwin)
        PLATFORM="macos"
        ;;
    Linux)
        PLATFORM="linux"
        ;;
    *)
        error "Unsupported operating system: $OS"
        ;;
esac

case "$ARCH_RAW" in
    arm64|aarch64)
        ARCH="arm64"
        ;;
    x86_64|amd64)
        ARCH="x64"
        ;;
    *)
        error "Unsupported architecture: $ARCH_RAW"
        ;;
esac

PLATFORM_LABEL="$PLATFORM"
ARCH_LABEL="$ARCH_RAW"
if [ "$PLATFORM" = "macos" ]; then
    PLATFORM_LABEL="macOS"
elif [ "$PLATFORM" = "linux" ]; then
    PLATFORM_LABEL="Linux"
fi

if [ "$ARCH" = "arm64" ]; then
    ARCH_LABEL="Apple Silicon"
elif [ "$ARCH" = "x64" ]; then
    ARCH_LABEL="Intel"
fi

TEMP_DIR="$(mktemp -d)"
MOUNT_POINT=""
cleanup() {
    if [ -n "${MOUNT_POINT:-}" ] && [ -d "$MOUNT_POINT" ]; then
        hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
    fi
    rm -rf "$TEMP_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

macos_embedr_is_running() {
    pgrep -f '/Applications/Embedr\.app/' >/dev/null 2>&1
}

close_running_embedr_macos() {
    if ! macos_embedr_is_running; then
        return 0
    fi

    info "Embedr is open. Trying to close it first..."

    if command -v osascript >/dev/null 2>&1; then
        osascript -e 'tell application "Embedr" to quit' >/dev/null 2>&1 || true
    fi
    pkill -TERM -x "Embedr" >/dev/null 2>&1 || true

    local waited=0
    while macos_embedr_is_running && [ "$waited" -lt 20 ]; do
        sleep 1
        waited=$((waited + 1))
    done

    if macos_embedr_is_running; then
        warn "Embedr is still running. Trying again..."
        pkill -TERM -f '/Applications/Embedr\.app/' >/dev/null 2>&1 || true
        waited=0
        while macos_embedr_is_running && [ "$waited" -lt 10 ]; do
            sleep 1
            waited=$((waited + 1))
        done
    fi

    if macos_embedr_is_running; then
        warn "Embedr is still open. Continuing with the reinstall anyway."
        return 0
    fi

    success "Embedr closed"
}

if [ "$PLATFORM" = "macos" ] && [ "${EUID:-$(id -u)}" -ne 0 ]; then
    info "macOS needs administrator access to update /Applications."
    SCRIPT_NAME="$(basename "$0" 2>/dev/null || true)"
    if [ ! -f "$0" ] || printf '%s' "$SCRIPT_NAME" | grep -qE '^-?(ba)?sh$'; then
        SCRIPT_TMP="$TEMP_DIR/install.sh"
        {
            printf '%s\n' '#!/usr/bin/env bash'
            printf '%s\n' "trap 'rm -f \"\$0\"; rmdir \"\$(dirname \"\$0\")\" 2>/dev/null || true' EXIT"
            curl -fsSL "$INSTALLER_BASE/install.sh"
        } > "$SCRIPT_TMP"
        chmod +x "$SCRIPT_TMP"
        exec sudo bash "$SCRIPT_TMP" "${ORIGINAL_ARGS[@]}"
    fi
    exec sudo "$0" "${ORIGINAL_ARGS[@]}"
fi

REQUESTED_VERSION="latest"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            [ "${2:-}" ] || error "--version requires a value"
            REQUESTED_VERSION="$2"
            shift 2
            ;;
        *)
            warn "Ignoring unknown option: $1"
            shift
            ;;
    esac
done

resolve_version() {
    local release_json=""
    local retry_delay=2

    if [ "$REQUESTED_VERSION" != "latest" ]; then
        VERSION_TAG="$REQUESTED_VERSION"
        case "$VERSION_TAG" in
            v*) ;;
            *) VERSION_TAG="v$VERSION_TAG" ;;
        esac
        VERSION_NUMBER="${VERSION_TAG#v}"
        return 0
    fi

    info "Checking the latest Embedr release..."
    for attempt in 1 2 3; do
        release_json="$(curl -fsSL --connect-timeout 10 --max-time 30 "$GITHUB_API/releases/latest" 2>/dev/null || true)"
        if [ -n "$release_json" ] && printf '%s' "$release_json" | grep -q '"tag_name"'; then
            VERSION_TAG="$(printf '%s' "$release_json" | grep '"tag_name"' | head -1 | cut -d '"' -f 4)"
            VERSION_NUMBER="${VERSION_TAG#v}"
            return 0
        fi

        if [ "$attempt" -eq 3 ]; then
            error "Failed to fetch release information after $attempt attempts"
        fi

        warn "Could not reach GitHub yet. Retrying in ${retry_delay}s..."
        sleep "$retry_delay"
        retry_delay=$((retry_delay * 2))
    done
}

asset_exists() {
    local url="$1"
    curl -fsIL --connect-timeout 10 --max-time 20 "$url" >/dev/null 2>&1
}

download_asset() {
    local destination="$1"
    shift

    local asset_name
    for asset_name in "$@"; do
        local url="$GITHUB_RELEASES/download/$VERSION_TAG/$asset_name"
        if asset_exists "$url"; then
            info "Downloading $asset_name"
            if curl --progress-bar -L --connect-timeout 10 --max-time 600 -o "$destination" "$url"; then
                DOWNLOADED_ASSET="$asset_name"
                return 0
            fi
        fi
    done

    return 1
}

install_macos() {
    local dmg_path="$TEMP_DIR/Embedr.dmg"
    local app_source=""
    local install_path="/Applications/Embedr.app"

    if [ "$ARCH" = "arm64" ]; then
        if ! download_asset "$dmg_path" "Embedr-${VERSION_NUMBER}-arm64.dmg" "Embedr-${VERSION_NUMBER}-arm64-mac.dmg"; then
            error "Could not find a macOS installer for $VERSION_TAG"
        fi
    else
        if ! download_asset "$dmg_path" "Embedr-${VERSION_NUMBER}.dmg" "Embedr-${VERSION_NUMBER}-x64.dmg" "Embedr-${VERSION_NUMBER}-mac.dmg"; then
            error "Could not find a macOS installer for $VERSION_TAG"
        fi
    fi

    info "Opening the installer image..."
    local mount_output
    mount_output="$(hdiutil attach "$dmg_path" -nobrowse -plist 2>&1)"
    MOUNT_POINT="$(printf '%s' "$mount_output" | grep -A1 '<key>mount-point</key>' | grep '<string>' | sed 's/.*<string>\(.*\)<\/string>.*/\1/' | head -1)"

    if [ -z "$MOUNT_POINT" ]; then
        mount_output="$(hdiutil attach "$dmg_path" -nobrowse 2>&1)"
        MOUNT_POINT="$(printf '%s' "$mount_output" | grep -o '/Volumes/[^"]*' | head -1)"
    fi

    if [ -z "$MOUNT_POINT" ] || [ ! -d "$MOUNT_POINT" ]; then
        error "Failed to mount disk image"
    fi

    app_source="$MOUNT_POINT/Embedr.app"
    if [ ! -d "$app_source" ]; then
        app_source="$(find "$MOUNT_POINT" -maxdepth 1 -name "*.app" | head -1)"
    fi

    if [ -z "$app_source" ] || [ ! -d "$app_source" ]; then
        error "Could not find Embedr.app in the disk image"
    fi

    if [ -d "$install_path" ]; then
        close_running_embedr_macos
        info "Replacing the existing app in /Applications..."
        rm -rf "$install_path"
    fi

    info "Copying Embedr to /Applications..."
    cp -R "$app_source" /Applications/
    xattr -dr com.apple.quarantine "$install_path" 2>/dev/null || true

    success "Embedr $VERSION_TAG is installed"
    info "Opening Embedr..."
    open "$install_path"
}

install_linux() {
    local install_dir="${XDG_DATA_HOME:-$HOME/.local/share}/embedr"
    local bin_dir="${XDG_BIN_HOME:-$HOME/.local/bin}"
    local appimage_path="$install_dir/Embedr.AppImage"
    local launcher_path="$bin_dir/embedr"

    mkdir -p "$install_dir" "$bin_dir"

    if [ "$ARCH" = "arm64" ]; then
        if ! download_asset "$appimage_path" \
            "Embedr-${VERSION_NUMBER}-arm64.AppImage" \
            "Embedr-${VERSION_NUMBER}-aarch64.AppImage" \
            "Embedr-${VERSION_NUMBER}.AppImage"; then
            error "Could not find a Linux AppImage for $VERSION_TAG"
        fi
    elif ! download_asset "$appimage_path" \
        "Embedr-${VERSION_NUMBER}-x86_64.AppImage" \
        "Embedr-${VERSION_NUMBER}-amd64.AppImage" \
        "Embedr-${VERSION_NUMBER}-x64.AppImage" \
        "Embedr-${VERSION_NUMBER}.AppImage"; then
        error "Could not find a Linux AppImage for $VERSION_TAG"
    fi

    chmod +x "$appimage_path"
    ln -sf "$appimage_path" "$launcher_path"

    success "Embedr $VERSION_TAG is installed"
    info "Launcher ready at $launcher_path"

    if ! command -v embedr >/dev/null 2>&1; then
        warn "If 'embedr' is not found, add $bin_dir to your PATH."
    fi

    info "Opening Embedr..."
    nohup "$appimage_path" >/dev/null 2>&1 &
}

resolve_version
headline
if [ "$REQUESTED_VERSION" = "latest" ]; then
    info "Installing the latest release on $PLATFORM_LABEL ($ARCH_LABEL)."
else
    info "Installing $VERSION_TAG on $PLATFORM_LABEL ($ARCH_LABEL)."
fi
success "Resolved version: $VERSION_TAG"

case "$PLATFORM" in
    macos)
        install_macos
        ;;
    linux)
        install_linux
        ;;
esac
