#!/usr/bin/env bash
# Devcroft installer.
#
# Fetch-and-pipe usage (no repo clone, no args):
#   curl -fsSL https://raw.githubusercontent.com/d0whc3r/devcroft/main/install.sh | sh
#
# What it does:
#   1. sanity-checks prerequisites (curl, tar; git is warn-only)
#   2. bootstraps mise via https://mise.run if it is not on PATH
#   3. downloads a GitHub source tarball (no git clone) into a temp dir
#   4. runs `mise install` against the repo's mise.toml (pinned rust + zig)
#   5. runs the repo's own ./scripts/install-app.sh through `mise exec`
#      so cargo is on PATH. install-app.sh does `cargo build --release`
#      itself and installs the desktop app + `~/.local/bin/devcroft` CLI.
#
# Overrides:
#   DEVCROFT_REPO=owner/name   GitHub repo to build from
#   DEVCROFT_REF=ref           branch, tag, or commit SHA (default: main)
#   DEVCROFT_DEBUG=1           build a debug binary instead of release
#
# Needs: curl, tar. Generates: mise (if missing). Warns-only: git
# (the installed app talks to git at runtime, but the install itself
# does not need it, so a missing git must not abort).
set -euo pipefail

DEFAULT_REPO="d0whc3r/devcroft"
DEFAULT_REF="main"

REPO="${DEVCROFT_REPO:-$DEFAULT_REPO}"
REF="${DEVCROFT_REF:-$DEFAULT_REF}"
BUILD_DEBUG=0
if [ "${DEVCROFT_DEBUG:-0}" = "1" ]; then
  BUILD_DEBUG=1
fi

TARBALL_URL="https://github.com/${REPO}/archive/${REF}.tar.gz"
MISE_INSTALLER_URL="https://mise.run"
# Default install path used by https://mise.run; we re-add it to PATH
# below because piping only changed the *current* process's PATH.
MISE_DEFAULT_BIN="$HOME/.local/bin/mise"
MISE_DEFAULT_BIN_DIR="$HOME/.local/bin"

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

# Sanity checks.
check_prereqs() {
  log "Step 1: checking prerequisites"
  command -v curl >/dev/null 2>&1 || die "curl is required (install curl and retry)"
  command -v tar >/dev/null 2>&1 || die "tar is required"
  OS="$(uname -s)"
  if [ "$OS" != "Darwin" ] && [ "$OS" != "Linux" ]; then
    die "unsupported OS: $OS (only macOS and Linux are supported)"
  fi
  if ! command -v git >/dev/null 2>&1; then
    warn "git not found on PATH; Devcroft needs git at run time (editor/git pages)."
    warn "Install git later with your package manager or xcode tools; continuing."
  fi
}

# Bootstrap mise when it is not already invokable.
#
# The https://mise.run installer is fully non-interactive (no tty, no
# consent prompts): it downloads a checksum-verified binary to
# $HOME/.local/bin/mise and only PRINTS shell-activation hints. Because
# it completes with a plain `sh`, it is safe in the curl|sh flow here.
bootstrap_mise() {
  log "Step 2: bootstrap mise"
  if ! command -v mise >/dev/null 2>&1; then
    echo "mise not found; installing via https://mise.run (non-interactive)"
    curl -fsSL "$MISE_INSTALLER_URL" | sh
    # `sh` above ran in a subshell for the pipe, but its PATH changes do
    # not outlive it: make the freshly installed binary invokable here.
    if [ -x "$MISE_DEFAULT_BIN" ]; then
      export PATH="$MISE_DEFAULT_BIN_DIR:$PATH"
    else
      # https://mise.run honours MISE_INSTALL_PATH only inside its own
      # subshell; if the default location is absent, fall back to probing.
      local candidate candidate_dir
      for candidate in /usr/local/bin/mise /usr/bin/mise /opt/homebrew/bin/mise; do
        if [ -x "$candidate" ]; then
          candidate_dir="$(dirname "$candidate")"
          export PATH="$candidate_dir:$PATH"
          return 0
        fi
      done
      die "mise bootstrap finished but $MISE_DEFAULT_BIN is missing"
    fi
  fi
  command -v mise >/dev/null 2>&1 || die "mise is still not on PATH after bootstrap"
  echo "mise: $(mise --version 2>/dev/null || echo unknown)"
}

# Download and extract the source tarball without cloning.
fetch_source() {
  log "Step 3: downloading source tarball ($REPO @ $REF)"
  TMP_DIR="$(mktemp -d)" || die "mktemp failed"
  # Stream straight into tar; no temp tarball on disk. With pipefail,
  # a mid-stream curl failure aborts the script.
  if ! curl -fsSL "$TARBALL_URL" | tar -xzf - -C "$TMP_DIR"; then
    die "failed to download/extract source tarball ($TARBALL_URL). Check that $REPO @ $REF exists."
  fi
  # GitHub tarballs extract into a single top-level dir: find it without
  # bash-4 features (mapfile is not available in macOS stock bash 3.2).
  for d in "$TMP_DIR"/*/; do
    if [ -d "$d" ]; then
      SRC_DIR="${d%/}"
      break
    fi
  done
  if [ -z "${SRC_DIR:-}" ]; then
    die "no extracted source directory found under $TMP_DIR"
  fi
  echo "extracted source into: $SRC_DIR"
}

# Install pinned toolchains (mise.toml -> rust, zig) then hand over to the
# repo's own installer inside `mise exec` so cargo is on PATH.
#
# The `mise exec` trick: mise reads mise.toml from the current working
# directory, so we must cd into the extracted source before invoking it.
# It prepends the pinned rust/zig installs to PATH for the child process.
build_and_install() {
  log "Step 4: installing pinned toolchains (mise install)"
  ( cd "$SRC_DIR" && mise install )

  log "Step 5: building and installing app (scripts/install-app.sh)"
  # Array (supported even in stock macOS bash 3.2) so --debug is passed
  # as its own argv entry without word-splitting.
  local -a install_args=(./scripts/install-app.sh)
  if [ "$BUILD_DEBUG" = "1" ]; then
    install_args+=(--debug)
  fi
  # install-app.sh runs `cargo build --release` itself: invoked once here.
  ( cd "$SRC_DIR" && mise exec -- bash "${install_args[@]}" )
}

print_summary() {
  log "Done"
  cat <<EOF

Devcroft installed successfully.

What was installed:
  - Desktop app build of devcroft (see output above for exact paths)
    macOS: /Applications/Devcroft.app (or ~/Applications fallback)
    Linux: ~/.local/bin/devcroft + devcroft.desktop launcher
  - CLI: $HOME/.local/bin/devcroft

Next steps:
  - Make sure $HOME/.local/bin is on your PATH (shell profile).
  - Launch the desktop app: Devcroft.app, or run: devcroft app
  - Install the bundled agent skill: devcroft skill install
  - The pinned toolchains are managed by mise. If mise was installed
    just now, activate it in future shells (https://mise.run only
    prints these hints), then start a fresh shell:
      sh:  echo 'eval "\$($HOME/.local/bin/mise activate sh)"' >> ~/.profile; exec \$SHELL
      zsh: echo 'eval "\$($HOME/.local/bin/mise activate zsh)"' >> ~/.zshrc
EOF
}

main() {
  echo "Devcroft installer — building from source, no repo clone required."
  check_prereqs
  bootstrap_mise
  fetch_source
  build_and_install
  print_summary
}

main
