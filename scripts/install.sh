#!/bin/sh
# Install lerian-infra.
#
#   curl -fsSL https://raw.githubusercontent.com/LerianStudio/lerian-terraform-foundation/main/scripts/install.sh | sh
#
# Downloads the release archive for this platform, VERIFIES IT against the
# published checksums, and installs the binary. The verification is the reason this
# script is worth piping to a shell at all: without it, the pipe is a download with
# extra steps.
#
# Environment:
#   LERIAN_INFRA_VERSION   tag to install (default: the latest release)
#   INSTALL_DIR            where to put the binary (default: see resolve_install_dir)
#
# POSIX sh on purpose: this runs before anything is installed, on whatever the
# machine happens to have.

set -eu

REPO="LerianStudio/lerian-terraform-foundation"
BINARY="lerian-infra"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required and was not found in PATH"
}

# ---------------------------------------------------------------------------
# Platform
#
# The names have to match what goreleaser produced, not what uname says:
# `title .Os` gives Darwin/Linux, and amd64 is published as x86_64.
# ---------------------------------------------------------------------------
detect_platform() {
    os=$(uname -s)
    arch=$(uname -m)

    case "$os" in
        Linux)  os=Linux ;;
        Darwin) os=Darwin ;;
        *)
            die "unsupported operating system: $os
Releases cover Linux and macOS. On Windows, download the .zip from
https://github.com/$REPO/releases and put lerian-infra.exe on your PATH." ;;
    esac

    case "$arch" in
        x86_64|amd64)  arch=x86_64 ;;
        arm64|aarch64) arch=arm64 ;;
        *)
            die "unsupported architecture: $arch
Releases cover x86_64 and arm64." ;;
    esac

    PLATFORM="${os}_${arch}"
}

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------
latest_version() {
    # The redirect on /releases/latest carries the tag, which avoids both a JSON
    # parser and the lower rate limit of the API.
    tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
        "https://github.com/$REPO/releases/latest" 2>/dev/null | sed 's|.*/tag/||')
    [ -n "$tag" ] || die "cannot determine the latest release
Set LERIAN_INFRA_VERSION to a tag, for example LERIAN_INFRA_VERSION=v1.6.0."
    printf '%s' "$tag"
}

# ---------------------------------------------------------------------------
# Install directory
#
# Preferring a writable directory over /usr/local/bin keeps the common case free
# of sudo. A script piped into a shell asking for a password is a bad habit to
# teach, so this one never calls sudo — it says what to do instead.
# ---------------------------------------------------------------------------
resolve_install_dir() {
    if [ -n "${INSTALL_DIR:-}" ]; then
        printf '%s' "$INSTALL_DIR"
        return
    fi
    for candidate in "$HOME/.local/bin" "$HOME/bin" /usr/local/bin; do
        if [ -d "$candidate" ] && [ -w "$candidate" ]; then
            printf '%s' "$candidate"
            return
        fi
    done
    # Nothing existed and was writable: create the XDG-ish default rather than
    # reaching for a system directory.
    printf '%s' "$HOME/.local/bin"
}

on_path() {
    case ":${PATH}:" in
        *":$1:"*) return 0 ;;
        *)        return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Checksum
# ---------------------------------------------------------------------------
verify() {
    archive=$1
    sums=$2
    expected=$(grep " ${archive}\$" "$sums" | awk '{print $1}')
    [ -n "$expected" ] || die "$archive is not listed in checksums.txt"

    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$archive" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$archive" | awk '{print $1}')
    else
        die "neither sha256sum nor shasum is available, so the download cannot be verified
Install one of them, or download and verify by hand from
https://github.com/$REPO/releases"
    fi

    [ "$actual" = "$expected" ] || die "checksum mismatch for $archive
  expected $expected
  got      $actual
The download is corrupt or has been tampered with. Nothing was installed."
}

main() {
    need curl
    need tar
    need awk

    detect_platform

    version=${LERIAN_INFRA_VERSION:-$(latest_version)}
    # The tag carries a leading v; the archive name does not. goreleaser builds it
    # from .Version, which is the tag with the v stripped.
    number=${version#v}

    archive="${BINARY}_${number}_${PLATFORM}.tar.gz"
    base="https://github.com/$REPO/releases/download/$version"

    tmp=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT INT TERM

    say "Downloading $BINARY $version for $PLATFORM"
    curl -fsSL "$base/$archive" -o "$tmp/$archive" \
        || die "cannot download $base/$archive
Check that $version is a released version with binaries attached."
    curl -fsSL "$base/checksums.txt" -o "$tmp/checksums.txt" \
        || die "cannot download the checksums for $version, so the archive cannot be verified"

    ( cd "$tmp" && verify "$archive" checksums.txt )
    say "Checksum verified"

    tar -xzf "$tmp/$archive" -C "$tmp" "$BINARY" \
        || die "cannot extract $BINARY from $archive"

    dir=$(resolve_install_dir)
    mkdir -p "$dir" || die "cannot create $dir"
    [ -w "$dir" ] || die "$dir is not writable
Set INSTALL_DIR to somewhere you can write, or copy $tmp/$BINARY yourself:
  sudo install -m 0755 <downloaded binary> /usr/local/bin/$BINARY"

    install -m 0755 "$tmp/$BINARY" "$dir/$BINARY" 2>/dev/null \
        || { cp "$tmp/$BINARY" "$dir/$BINARY" && chmod 0755 "$dir/$BINARY"; } \
        || die "cannot install into $dir"

    say "Installed $dir/$BINARY"

    if on_path "$dir"; then
        say ""
        say "Next: lerian-infra init --env dev --clone"
    else
        say ""
        say "$dir is not on your PATH. Add it:"
        say "  export PATH=\"$dir:\$PATH\""
    fi
}

main "$@"
