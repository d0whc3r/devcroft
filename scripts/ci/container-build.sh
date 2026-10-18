#!/usr/bin/env bash
# Build one release target INSIDE the warm CI image (ghcr.io/*-devcroft-ci).
#
# Invoked from release.yml by its `docker run` step:
#
#     docker run ... "$CI_IMAGE" bash /workspace/scripts/ci/container-build.sh
#
# The workspace checkout is mounted at /workspace (fixed absolute path the
# image's baked fingerprints reference), and deps were prebuilt into
# /target-warm during the image bake stage (Dockerfile.ci `deps-bake`), so
# cargo validates influencers instead of recompiling the dependency graph —
# only devcroft (plus any locally-changed crates) compile and link here.
#
# Inputs (must be passed via docker run -e from release.yml):
#   TARGET                 plain triple, e.g. x86_64-unknown-linux-gnu
#   RUST_PIN / ZIG_PIN / CARGO_ZIGBUILD_VERSION   pins from mise.toml
#   SDKROOT                optional (darwin targets only); unsets handled
#
# Hard-fail behavior: any toolchain pin drift aborts BEFORE building, so a
# stale image can never silently produce half-warm builds. On build failure,
# diagnostics (zig/rustc/zigbuild/SDKROOT) always print, then the script
# exits with the build's own status.
set -u

: "${TARGET:?release.yml must set TARGET (plain triple)}"
: "${RUST_PIN:?release.yml must set RUST_PIN from mise.toml}"
: "${ZIG_PIN:?release.yml must set ZIG_PIN from mise.toml}"
: "${CARGO_ZIGBUILD_VERSION:?release.yml must set CARGO_ZIGBUILD_VERSION}"

status=0

echo "=== toolchain inspection ==="
echo "zig:     $(which zig)   $(zig version)"
echo "rustc:   $(which rustc)   $(rustc --version)"
echo "zigbuild: $(which cargo-zigbuild)   $(cargo-zigbuild --version)"
echo "SDKROOT: ${SDKROOT:-<unset>}"
echo "CARGO_TARGET_DIR: ${CARGO_TARGET_DIR:-<unset>} (should be the image's baked /target-warm)"

echo "=== pin validation (mise.toml: rust=$RUST_PIN zig=$ZIG_PIN zigbuild=$CARGO_ZIGBUILD_VERSION) ==="
if ! zig version | grep -qx "$ZIG_PIN"; then
  echo "::error::zig pin drift: expected $ZIG_PIN, got $(zig version)"; status=1
fi
if ! rustc --version | grep -qE "^rustc ${RUST_PIN} "; then
  echo "::error::rustc pin drift: expected rustc $RUST_PIN, got $(rustc --version)"; status=1
fi
if ! cargo-zigbuild --version | grep -qE "^cargo-zigbuild ${CARGO_ZIGBUILD_VERSION}[[:space:]]*$"; then
  echo "::error::cargo-zigbuild pin drift: expected $CARGO_ZIGBUILD_VERSION, got $(cargo-zigbuild --version)"; status=1
fi
if ! rustup target list --installed | grep -qx "$TARGET"; then
  echo "::error::rust target not installed in image: $TARGET"; status=1
fi
# Warn (not fail) if this target has no baked deps: an outdated image still
# builds, just cold — never silently: the warning plus the total job wall
# time make the staleness obvious.
if [ ! -d "${CARGO_TARGET_DIR:-/target-warm}/$TARGET/release/build" ]; then
  echo "::warning::no baked deps for $TARGET in ${CARGO_TARGET_DIR:-/target-warm} — this run compiles the full graph cold; consider rebuilding the ci image"
fi
[ "$status" -eq 0 ] || exit "$status"

# Linux-gnu: zigbuild defaults to glibc 2.17 stubs, but the ubuntu-24.04
# system libs we link (libxkbcommon etc.) reference glibc >= 2.38 symbols
# (e.g. __isoc23_strtoul@GLIBC_2.38) that 2.17 stubs lack. Pinning .2.38
# defines those symbols in the linker stub map. The image bake stage builds
# with the SAME suffixed target so fingerprints match at run time.
case "$TARGET" in
  *-linux-gnu) ZIG_TARGET="$TARGET.2.38" ;;
  *)           ZIG_TARGET="$TARGET" ;;
esac

echo "=== cargo zigbuild --release --locked --target $ZIG_TARGET ==="
cargo zigbuild --release --locked --target "$ZIG_TARGET"
status=$?
if [ "$status" -ne 0 ]; then
  echo "::warning::cargo zigbuild failed (status=$status) — diagnostics follow"
  echo "which zig  : $(which zig)"; zig version
  echo "cargo-zigbuild: $(which cargo-zigbuild)   $(cargo-zigbuild --version)"
  echo "SDKROOT: ${SDKROOT:-<unset>}"
  exit "$status"
fi

echo "=== post-build diagnostics ==="
echo "zig version      : $(zig version)"
echo "cargo zigbuild   : $(cargo-zigbuild --version)"
echo "SDKROOT          : ${SDKROOT:-<unset>}"
echo "built binary     : $(ls -l "$CARGO_TARGET_DIR/$ZIG_TARGET/release/devcroft")"

# Copy the fresh binary to the workspace path the runner-side packaging steps
# expect (target/<plain-triple>/release/devcroft). /target-warm lives on the
# container's overlay fs and dies with `docker run --rm`, so this copy is how
# the binary escapes the container.
out_dir="/workspace/target/$TARGET/release"
mkdir -p "$out_dir"
cp "$CARGO_TARGET_DIR/$ZIG_TARGET/release/devcroft" "$out_dir/devcroft"
ls -l "$out_dir/devcroft"
