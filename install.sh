#!/usr/bin/env bash
# Devcroft installer.
#
# README invocation (no clone, no toolchains, no compilation, no git):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/d0whc3r/devcroft/main/install.sh)"
#
# What it does:
#   1. checks prerequisites and detects OS/architecture
#   2. resolves the release download URLs
#   3. downloads the prebuilt asset and its SHA256SUMS from GitHub Releases
#   4. verifies the asset against the published sha256 (aborts on mismatch)
#   5. installs the single `devcroft` binary into $HOME/.local/bin
#   6. smoke-checks the binary and prints a PATH hint when needed
#
# Overrides:
#   DEVCROFT_REPO         GitHub repo to download from (default d0whc3r/devcroft)
#   DEVCROFT_VERSION      "latest" (default) or a release version such as
#                         "0.2.1" or "v0.2.1"
#   DEVCROFT_INSTALL_DIR  destination directory (default $HOME/.local/bin)
#
# Writes only to the install directory and a self-cleaning temp dir. It never
# prompts and never edits rc files: safe for unsupervised curl|bash.
# Needs: curl, tar, and a sha256 tool (shasum on macOS, sha256sum on Linux;
# either works as a fallback). Bash >= 3.2 (macOS stock bash is fine).
set -euo pipefail

DEFAULT_REPO="d0whc3r/devcroft"
REPO="${DEVCROFT_REPO:-$DEFAULT_REPO}"
INSTALL_DIR="${DEVCROFT_INSTALL_DIR:-${HOME}/.local/bin}"

TMP_DIR=""

log()  { echo "==> $*"; }
warn() { echo "warning: $*" >&2; }
die()  { echo "error: $*" >&2; exit 1; }

cleanup() {
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

# Map a platform onto the release asset naming convention
# devcroft-<os>-<arch>.tar.gz with os ∈ {darwin, linux} and
# arch ∈ {arm64, x86_64}. Both args are testable: with no args this machine
# is detected, otherwise sys/arch are given explicitly. aarch64 -> arm64.
detect_platform() {
  local sys="${1:-$(uname -s)}" arch="${2:-$(uname -m)}"
  case "$sys" in
    Darwin) OS_NAME="darwin" ;;
    Linux)  OS_NAME="linux" ;;
    *) die "unsupported OS: $sys (only macOS and Linux are supported)" ;;
  esac
  case "$arch" in
    arm64|aarch64) ARCH="arm64" ;;
    x86_64|amd64)  ARCH="x86_64" ;;
    *) die "unsupported architecture: $arch (only arm64/aarch64 and x86_64 are supported)" ;;
  esac
  ASSET="devcroft-${OS_NAME}-${ARCH}.tar.gz"
}

# Resolve the download base URL. "latest" uses GitHub's stable redirect
# (…/releases/latest/download/<asset>) to avoid API rate limits; pinned
# versions use their tag URL (…/releases/download/vX.Y.Z/<asset>), with or
# without the leading "v" accepted on input.
resolve_urls() {
  local version="${DEVCROFT_VERSION:-latest}"
  if [ "$version" = "latest" ]; then
    BASE_URL="https://github.com/${REPO}/releases/latest/download"
    VERSION_LABEL="latest"
  else
    version="${version#v}"
    BASE_URL="https://github.com/${REPO}/releases/download/v${version}"
    VERSION_LABEL="v${version}"
  fi
  ASSET_URL="${BASE_URL}/${ASSET}"
  SUMS_URL="${BASE_URL}/SHA256SUMS"
}

check_prereqs() {
  log "Step 1: checking prerequisites"
  command -v curl >/dev/null 2>&1 || die "curl is required (install curl and retry)"
  command -v tar >/dev/null 2>&1 || die "tar is required"
  detect_platform
  echo "platform: $OS_NAME/$ARCH -> $ASSET"
}

# sha256 digest of a file, preferring the standard tool for the detected OS.
sha256_of() {
  local tool
  case "$OS_NAME" in
    darwin) tool="shasum" ;;
    *)      tool="sha256sum" ;;
  esac
  if ! command -v "$tool" >/dev/null 2>&1; then
    case "$tool" in shasum) tool="sha256sum" ;; *) tool="shasum" ;; esac
  fi
  command -v "$tool" >/dev/null 2>&1 || die "need a sha256 tool (sha256sum or shasum)"
  case "$tool" in
    shasum) shasum -a 256 "$1" | awk '{print $1}' ;;
    *)      sha256sum "$1" | awk '{print $1}' ;;
  esac
}

# Download asset + SHA256SUMS, verify, and extract.
fetch_and_verify() {
  log "Step 3: downloading prebuilt binary ($VERSION_LABEL) from $REPO"
  curl -fsSL --retry 3 -o "$TMP_DIR/$ASSET" "$ASSET_URL" \
    || die "failed to download $ASSET_URL — check that $REPO has a $VERSION_LABEL release with this asset"
  log "Step 4: verifying SHA-256 checksum"
  curl -fsSL --retry 3 -o "$TMP_DIR/SHA256SUMS" "$SUMS_URL" \
    || die "failed to download $SUMS_URL (needed for checksum verification)"
  local expected actual
  expected="$(awk -v a="$ASSET" 'NF >= 2 && $2 == a {print $1; exit}' "$TMP_DIR/SHA256SUMS")"
  [ -n "$expected" ] || die "no sha256 entry for $ASSET in SHA256SUMS — refusing to install an unverified binary"
  actual="$(sha256_of "$TMP_DIR/$ASSET")"
  if [ "$expected" != "$actual" ]; then
    die "SHA-256 mismatch for $ASSET: expected $expected, got $actual. The download may be corrupted or tampered with — aborting."
  fi
  echo "checksum OK: $expected"
  tar -xzf "$TMP_DIR/$ASSET" -C "$TMP_DIR" \
    || die "failed to extract $ASSET (is it a valid gzip tarball?)"
  BIN_PATH="$TMP_DIR/devcroft"
  if [ ! -f "$BIN_PATH" ]; then
    local f
    for f in "$TMP_DIR"/*/devcroft "$TMP_DIR"/*/target/release/devcroft; do
      if [ -f "$f" ]; then
        BIN_PATH="$f"
        break
      fi
    done
  fi
  [ -f "$BIN_PATH" ] || die "no devcroft binary found inside $ASSET"
}

install_binary() {
  log "Step 5: installing devcroft to $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  if command -v install >/dev/null 2>&1; then
    install -m 0755 "$BIN_PATH" "$INSTALL_DIR/devcroft"
  else
    cp "$BIN_PATH" "$INSTALL_DIR/devcroft"
    chmod 0755 "$INSTALL_DIR/devcroft"
  fi
}

# Best-effort PATH check + hint. We never edit rc files ourselves; the user
# runs the exact export line we print.
print_path_hint() {
  case ":$PATH:" in
    *":$INSTALL_DIR:"*) return 0 ;;
  esac
  warn "$INSTALL_DIR is not on this shell's PATH"
  echo "Add it to your shell profile, then start a new shell:"
  case "$(basename "${SHELL:-bash}")" in
    zsh)  echo "  echo 'export PATH=\"$INSTALL_DIR:\$PATH\"' >> ~/.zshrc" ;;
    fish) echo "  fish_add_path $INSTALL_DIR" ;;
    *)    echo "  echo 'export PATH=\"$INSTALL_DIR:\$PATH\"' >> ~/.bashrc   # or ~/.profile" ;;
  esac
}

confirm_and_summarize() {
  log "Step 6: smoke check"
  if "$INSTALL_DIR/devcroft" --version >/dev/null 2>&1; then
    echo "smoke check OK: $("$INSTALL_DIR/devcroft" --version 2>/dev/null | head -n1)"
  else
    warn "'$INSTALL_DIR/devcroft --version' did not run cleanly; installation is complete, but report it if the binary misbehaves."
  fi
  print_path_hint
  log "Done"
  cat <<EOF

Devcroft installed successfully.

  binary:  $INSTALL_DIR/devcroft

Next steps:
    devcroft skill install      # install the bundled agent skill
    devcroft app                # full workspace GUI
EOF
}

main() {
  echo "Devcroft installer — prebuilt binary download (no clone, no build)."
  TMP_DIR="$(mktemp -d)" || die "mktemp failed"
  check_prereqs
  resolve_urls
  fetch_and_verify
  install_binary
  confirm_and_summarize
}

main
