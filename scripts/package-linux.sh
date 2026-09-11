#!/usr/bin/env bash
#
# Turn a built Flutter Linux bundle (app/seance_app/build/linux/<arch>/release/
# bundle) into installable Linux artifacts:
#
#   seance_<version>-1_<arch>.deb  — Debian/Ubuntu package (dpkg-deb; no
#                                    fakeroot needed, --root-owner-group is
#                                    used). Skipped, with a notice, on hosts
#                                    without dpkg-deb (Arch/Fedora/…) — the
#                                    AppImage below is what covers those.
#   seance-linux-<x64|arm64>.AppImage  — distro-independent portable image
#                                    (needs appimagetool; fetched once and
#                                    cached unless APPIMAGETOOL points at one)
#
# Everything is derived from the actual build output: the dependency list of
# the .deb is read from the ELF headers of the bundle (readelf NEEDED + a
# soname→package table, with the Ubuntu 24.04 "t64" rename handled as dpkg
# alternatives), and the glibc/libstdc++ floors from the symbol versions the
# bundle references — so a plugin or toolchain change can't silently make the
# shipped Depends stale. Unknown sonames fail the build on purpose: adding a
# plugin that links a new system library must force a conscious table update.
#
# Usage:
#   scripts/package-linux.sh                     # deb + AppImage → dist/
#   scripts/package-linux.sh --skip-appimage     # just the .deb
#   scripts/package-linux.sh --appimage=best-effort   # don't fail when the
#                                    appimagetool download can't be fetched
#   scripts/package-linux.sh --print-deps        # show the computed Depends
#   scripts/package-linux.sh --bundle <dir> --output-dir <dir>
#
# Environment:
#   APPIMAGETOOL      path to (or URL of) an appimagetool AppImage
#                     [default: pinned 1.9.1 release, cached in ~/.cache/seance]
#
# CI (.github/workflows/{ci,release}.yml) runs this right after
# `flutter build linux --release`; scripts/build.sh runs it from its `app`
# target on Linux hosts. The .rpm/Flatpak formats are deliberately not built —
# non-Debian users get the AppImage (see docs/STATUS.md).
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/app/seance_app"
BUNDLE=""
PROFILE="release"
OUT_DIR="$ROOT/dist"
APPIMAGE_MODE="required"   # required | best-effort | skip
PRINT_DEPS=false

usage() {
  awk 'NR==1 && /^#!/ {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$SELF"
  exit "${1:-0}"
}

die() { echo "package-linux: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --bundle) BUNDLE="${2:?}"; shift 2 ;;
    --profile) PROFILE="${2:?}"; shift 2 ;;
    --output-dir) OUT_DIR="${2:?}"; shift 2 ;;
    --appimage) APPIMAGE_MODE="${2:?}"; shift 2 ;;
    --appimage=*) APPIMAGE_MODE="${1#*=}"; shift ;;
    --skip-appimage) APPIMAGE_MODE="skip"; shift ;;
    --print-deps) PRINT_DEPS=true; shift ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done

[[ "$APPIMAGE_MODE" =~ ^(required|best-effort|skip)$ ]] \
  || die "--appimage must be required|best-effort|skip (got: $APPIMAGE_MODE)"

command -v readelf >/dev/null 2>&1 \
  || die "readelf not found — install binutils (the .deb dependency list is derived from the ELF headers)"

# ---------------------------------------------------------------------------
# Locate the bundle and derive the architecture from it (not from uname: the
# point of packaging is what's IN the bundle).
# ---------------------------------------------------------------------------
if [[ -z "$BUNDLE" ]]; then
  # Prefer the requested profile, fall back to the other one.
  if [[ "$PROFILE" == "debug" ]]; then SEARCH=(debug release); else SEARCH=(release debug); fi
  for p in "${SEARCH[@]}"; do
    BUNDLE="$(ls -d "$APP_DIR"/build/linux/*/"$p"/bundle 2>/dev/null | head -1 || true)"
    [[ -n "$BUNDLE" ]] && { PROFILE="$p"; break; }
  done
  [[ -n "$BUNDLE" ]] || die "no built bundle found under $APP_DIR/build/linux/*/…/bundle — run 'flutter build linux --release' first (or pass --bundle)"
fi
[[ -f "$BUNDLE/seance_app" ]] || die "$BUNDLE has no seance_app executable — not a Séance Linux bundle?"

case "$BUNDLE" in
  */linux/x64/*|*/linux-x64/*) FLUTTER_ARCH="x64" ;;
  */linux/arm64/*|*/linux-arm64/*) FLUTTER_ARCH="arm64" ;;
  *) # Custom --bundle path: ask the ELF itself.
     case "$(readelf -h "$BUNDLE/seance_app" | sed -n 's/.*Machine:[[:space:]]*//p')" in
       *"X86-64"*) FLUTTER_ARCH="x64" ;;
       *"AArch64"*) FLUTTER_ARCH="arm64" ;;
       *) die "cannot determine architecture of $BUNDLE/seance_app" ;;
     esac ;;
esac
case "$FLUTTER_ARCH" in
  x64)   DEB_ARCH="amd64";  APPIMAGE_ARCH="x86_64" ;;
  arm64) DEB_ARCH="arm64";  APPIMAGE_ARCH="aarch64" ;;
esac

VERSION="$(sed -n 's/^version:[[:space:]]*//p' "$APP_DIR/pubspec.yaml" | head -1)"
VERSION="${VERSION%%+*}"   # strip the Flutter build number, if any
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "bad/missing version in $APP_DIR/pubspec.yaml (got '${VERSION:-nothing}')"
DEB_VERSION="$VERSION-1"

echo "Packaging Séance $DEB_VERSION ($FLUTTER_ARCH → deb:$DEB_ARCH appimage:$APPIMAGE_ARCH)"
echo "  bundle: $BUNDLE"

# ---------------------------------------------------------------------------
# Dependency derivation. All ELFs in the bundle (exe + lib/*.so), their
# DT_NEEDED entries mapped to Debian packages; sonames that ship *inside* the
# bundle (plugins, the engine) are not dependencies. The "t64" alternatives
# cover the 64-bit-time_t package renames in Ubuntu 24.04/Debian 13 — the
# library files and sonames are identical, only the package names changed.
# ---------------------------------------------------------------------------
ELFS=("$BUNDLE/seance_app")
while IFS= read -r so; do ELFS+=("$so"); done < <(find "$BUNDLE/lib" -name '*.so*' -type f | sort)

declare -A SONAME_TO_DEP=(
  # glibc + toolchain runtimes
  [ld-linux-x86-64.so.2]='libc6'  [ld-linux-aarch64.so.1]='libc6'
  [libc.so.6]='libc6'  [libm.so.6]='libc6'  [libdl.so.2]='libc6'
  [libpthread.so.0]='libc6'  [librt.so.1]='libc6'  [libresolv.so.2]='libc6'
  [libgcc_s.so.1]='libgcc-s1'
  [libstdc++.so.6]='libstdc++6'
  # GTK stack
  [libgtk-3.so.0]='libgtk-3-0 | libgtk-3-0t64'
  [libgdk-3.so.0]='libgtk-3-0 | libgtk-3-0t64'
  [libglib-2.0.so.0]='libglib2.0-0 | libglib2.0-0t64'
  [libgio-2.0.so.0]='libglib2.0-0 | libglib2.0-0t64'
  [libgobject-2.0.so.0]='libglib2.0-0 | libglib2.0-0t64'
  [libgmodule-2.0.so.0]='libglib2.0-0 | libglib2.0-0t64'
  [libatk-1.0.so.0]='libatk1.0-0 | libatk1.0-0t64'
  [libcairo.so.2]='libcairo2'
  [libcairo-gobject.so.2]='libcairo2'
  [libgdk_pixbuf-2.0.so.0]='libgdk-pixbuf-2.0-0 | libgdk-pixbuf-2.0-0t64'
  [libpango-1.0.so.0]='libpango-1.0-0 | libpango-1.0-0t64'
  [libpangocairo-1.0.so.0]='libpangocairo-1.0-0 | libpangocairo-1.0-0t64'
  [libharfbuzz.so.0]='libharfbuzz0b'
  [libfontconfig.so.1]='libfontconfig1'
  [libepoxy.so.0]='libepoxy0'
  [libz.so.1]='zlib1g'
  # flutter_secure_storage' keyring backend
  [libsecret-1.so.0]='libsecret-1-0'
  # libsecret pulls gcrypt via pinentry on some setups; harmless if unused.
  [libgcrypt.so.20]='libgcrypt20'
)

# Sonames that are deliberately NOT Depends entries — known-conditional deps
# of vendored native assets, loaded lazily and only if the app ever uses the
# owning package. libjvm.so: needed by libdartjni.so (package:jni's native
# asset, which enters the graph via path_provider_android but is never used
# by Séance on Linux) — a JRE in Depends would be absurd for this app. If JNI
# ever becomes a real dependency, drop the entry and depend on a JRE instead.
declare -A SONAME_OPTIONAL=([libjvm.so]='package:jni native asset; lazily dlopen-ed, unused by Seance')

UNKNOWN=()
UNKNOWN_DETAIL=()   # "file → soname" — attribution for the error message
declare -A DEP_SEEN=()
declare -a DEP_STRS=()
dep_add() {  # $1 = dependency string; may be "pkg | pkg-t64" (contains spaces)
  local key="${1%% |*}"   # dedupe on the first package name
  if [[ -n "${DEP_SEEN[$key]:-}" ]]; then return 0; fi
  DEP_SEEN["$key"]=1
  DEP_STRS+=("$1")
}
dep_version() {  # $1 = package (never carries alternatives), $2 = versioned string
  local i found=0
  for i in "${!DEP_STRS[@]}"; do
    if [[ "${DEP_STRS[$i]}" == "$1" || "${DEP_STRS[$i]}" == "$1 "* ]]; then
      DEP_STRS[$i]="$2"; found=1; break
    fi
  done
  if [[ $found -eq 0 ]]; then dep_add "$2"; fi
}

for f in "${ELFS[@]}"; do
  while IFS= read -r soname; do
    [[ -z "$soname" ]] && continue
    # Bundled, not a system dep: the engine and the plugins live in lib/.
    [[ -e "$BUNDLE/lib/$soname" ]] && continue
    if [[ -n "${SONAME_TO_DEP[$soname]:-}" ]]; then
      dep_add "${SONAME_TO_DEP[$soname]}"
    elif [[ -n "${SONAME_OPTIONAL[$soname]:-}" ]]; then
      continue   # documented non-dependency (see SONAME_OPTIONAL above)
    else
      UNKNOWN+=("$soname")
      UNKNOWN_DETAIL+=("$(basename "$f") → $soname")
    fi
  done < <(readelf -d "$f" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')
done
if ((${#UNKNOWN[@]})); then
  die "unmapped soname(s): ${UNKNOWN[*]} — add them to SONAME_TO_DEP in $SELF (check: dpkg -S /usr/lib/*/libX.so.N). Needed by: ${UNKNOWN_DETAIL[*]}"
fi

# Version floors from the symbol versions actually referenced — what
# dh_shlibdeps would compute for us. Only meaningful for the base runtimes.
floor_of() {  # $1 = objdump tag prefix (e.g. GLIBC_), max across all ELFs
  # sort -Vu is version-aware (2.14 > 2.9); trust it instead of re-comparing.
  # `|| true`: grep exits 1 when a file references none of the tags, and
  # pipefail would turn that into a failure of the whole function.
  local tag="$1" f
  for f in "${ELFS[@]}"; do
    objdump -T "$f" 2>/dev/null | grep -o "${tag}[0-9.]*" || true
  done | sed "s/^$tag//" | sort -Vu | tail -1
}
GLIBC_FLOOR="$(floor_of GLIBC_)"
GLIBCXX_FLOOR="$(floor_of GLIBCXX_)"
GCC_FLOOR="$(floor_of GCC_)"

if [[ -n "$GLIBC_FLOOR"  ]]; then dep_version libc6      "libc6 (>= $GLIBC_FLOOR)"; fi
if [[ -n "$GLIBCXX_FLOOR" ]]; then dep_version libstdc++6 "libstdc++6 (>= $GLIBCXX_FLOOR)"; fi
if [[ -n "$GCC_FLOOR"    ]]; then dep_version libgcc-s1   "libgcc-s1 (>= $GCC_FLOOR)"; fi

# dpkg control wants ", " separators, in a stable order (alternatives keep
# their internal "|" order; sort only whole entries).
DEPENDS=""
while IFS= read -r d; do DEPENDS+=",$d"; done < <(printf '%s\n' "${DEP_STRS[@]}" | sort)
DEPENDS="${DEPENDS#,}"
DEPENDS="${DEPENDS//,/, }"

if $PRINT_DEPS; then
  echo "Depends: $DEPENDS"
  exit 0
fi
echo "  depends: $DEPENDS"

# ---------------------------------------------------------------------------
# Icon generation — the one vector-of-truth master, resized into hicolor.
# image magick: prefer `magick` (IM7), fall back to `convert` (IM6). Without
# either, fall back to shipping the master as a pixmaps icon (every desktop
# environment finds /usr/share/pixmaps) and say so.
# ---------------------------------------------------------------------------
MASTER_ICON="$ROOT/media-sources/seance-icon.png"
[[ -f "$MASTER_ICON" ]] || die "master icon not found: $MASTER_ICON"

ICON_SIZES=(16 24 32 48 64 96 128 256 512)
make_icon() {  # $1 src, $2 out png, $3 size
  if command -v magick >/dev/null 2>&1; then
    magick "$1" -resize "${3}x${3}" "$2"
  elif command -v convert >/dev/null 2>&1; then
    convert "$1" -resize "${3}x${3}" "$2"
  else
    return 1
  fi
}

install_icons() {  # $1 = destination usr/ root (deb tree or AppDir)
  local usr="$1" ok=1
  for size in "${ICON_SIZES[@]}"; do
    mkdir -p "$usr/share/icons/hicolor/${size}x${size}/apps"
    make_icon "$MASTER_ICON" "$usr/share/icons/hicolor/${size}x${size}/apps/seance.png" "$size" || { ok=0; break; }
  done
  if [[ $ok -eq 1 ]]; then
    return 0
  fi
  echo ".. package-linux: no ImageMagick found — installing the unresized master icon to pixmaps" >&2
  rm -rf "$usr/share/icons/hicolor"
  mkdir -p "$usr/share/pixmaps"
  cp "$MASTER_ICON" "$usr/share/pixmaps/seance.png"
}

write_desktop_file() {  # $1 = path, $2 = Exec value
  cat > "$1" <<EOF
[Desktop Entry]
Type=Application
Name=Séance
GenericName=SSH Client
Comment=Summon remote machines and talk to them
Exec=$2
Icon=seance
Terminal=false
Categories=Network;System;Utility;
# The GApplication id is also the prgname GTK reports to the session (seen
# in its warnings: "(com.lkm.seance_app:pid): …"), hence StartupWMClass —
# that's what lets desktops map windows onto this entry.
StartupWMClass=com.lkm.seance_app
EOF
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# The .deb. The staged usr/ tree is shared with the AppImage below, so a host
# without dpkg-deb (Arch, Fedora, …) still gets that.
# ---------------------------------------------------------------------------
HAVE_DPKG=false
if command -v dpkg-deb >/dev/null 2>&1; then
  HAVE_DPKG=true
else
  if [[ "$APPIMAGE_MODE" == "skip" ]]; then
    die "dpkg-deb not found and the AppImage is skipped — nothing to build"
  fi
  echo ".. no dpkg-deb on this host — building the AppImage only (the .deb needs a Debian-family host)" >&2
fi

DEBROOT="$WORK/deb"
install -d "$DEBROOT/usr/lib/seance" "$DEBROOT/usr/bin" \
            "$DEBROOT/usr/share/applications" "$DEBROOT/usr/share/doc/seance" \
            "$DEBROOT/DEBIAN"

# The bundle is self-relocatable (RPATH $ORIGIN/lib), so /usr/lib/seance works
# anywhere; strip the runner's symbols (the engine and plugins come stripped).
cp -a "$BUNDLE/." "$DEBROOT/usr/lib/seance/"
if command -v strip >/dev/null 2>&1; then
  strip --strip-unneeded "$DEBROOT/usr/lib/seance/seance_app" 2>/dev/null || true
fi

# A wrapper rather than a symlink: the runner computes its data/lib paths from
# its own executable location, and a wrapper keeps `seance` on PATH trivially.
cat > "$DEBROOT/usr/bin/seance" <<'EOF'
#!/bin/sh
exec /usr/lib/seance/seance_app "$@"
EOF
chmod 755 "$DEBROOT/usr/bin/seance"

write_desktop_file "$DEBROOT/usr/share/applications/seance.desktop" "seance"
install_icons "$DEBROOT/usr"

cat > "$DEBROOT/usr/share/doc/seance/copyright" <<EOF
Séance — a personal cross-platform SSH client
Source: https://github.com/L-K-M/Seance
License: as published in the source repository above.
Upstream-Version: $VERSION
EOF

cat > "$DEBROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
# Refresh the desktop/icon caches if the tools exist; a missing tool (or
# cache refresh failing) must never fail the package install.
if [ -x "$(command -v update-desktop-database)" ]; then
  update-desktop-database -q /usr/share/applications || true
fi
if [ -x "$(command -v gtk-update-icon-cache)" ]; then
  gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi
EOF
chmod 755 "$DEBROOT/DEBIAN/postinst"

INSTALLED_SIZE="$(du -sk "$DEBROOT/usr" | cut -f1)"
sed -e "s/@VERSION@/$DEB_VERSION/" -e "s/@ARCH@/$DEB_ARCH/" \
    -e "s/@DEPENDS@/$DEPENDS/" -e "s/@SIZE@/$INSTALLED_SIZE/" \
    > "$DEBROOT/DEBIAN/control" <<'EOF'
Package: seance
Version: @VERSION@
Section: net
Priority: optional
Architecture: @ARCH@
Installed-Size: @SIZE@
Depends: @DEPENDS@
Maintainer: L-K-M <l-k-m@users.noreply.github.com>
Homepage: https://github.com/L-K-M/Seance
Description: Séance — a personal cross-platform SSH client
 SSH client with trust-on-first-use host keys, an E2E-encrypted optional
 sync server, SFTP file browsing, and a built-in LLM assistant.
 You summon remote machines and talk to them.
EOF

DEB_NAME="seance_${DEB_VERSION}_${DEB_ARCH}.deb"
if $HAVE_DPKG; then
  echo "-- dpkg-deb → $DEB_NAME"
  dpkg-deb --root-owner-group --build "$DEBROOT" "$WORK/$DEB_NAME" >/dev/null
fi

# ---------------------------------------------------------------------------
# The AppImage: same payload as the deb (shares the staged usr/), an AppRun
# wrapper instead of /usr/bin, and the desktop entry at the AppDir root.
# ---------------------------------------------------------------------------
# Sets APPIMAGE_TOOL: the env override (path or URL) or the pinned release
# asset for this build host, downloaded once into ~/.cache/seance.
APPIMAGE_TOOL=""
resolve_appimagetool() {
  local host_arch url
  case "$(uname -m)" in
    x86_64) host_arch="x86_64" ;;
    aarch64|arm64) host_arch="aarch64" ;;
    *) die "appimagetool has no build for $(uname -m)" ;;
  esac
  url="${APPIMAGETOOL:-https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-$host_arch.AppImage}"
  if [[ "$url" != http* ]]; then   # a path, not a URL
    [[ -x "$url" ]] || die "APPIMAGETOOL=$url is not executable"
    APPIMAGE_TOOL="$url"; return 0
  fi
  local cache
  cache="$HOME/.cache/seance/$(basename "$url")"
  if [[ ! -x "$cache" ]]; then
    echo "-- fetching appimagetool ($url)"
    mkdir -p "$(dirname "$cache")"
    command -v curl >/dev/null 2>&1 || die "curl not found (set APPIMAGETOOL to a local appimagetool)"
    curl -fL --retry 3 -o "$cache.part" "$url" && chmod 755 "$cache.part" && mv "$cache.part" "$cache"
  fi
  APPIMAGE_TOOL="$cache"
}

# appimagetool shells out to `file` (and to mksquashfs, which it bundles);
# check upfront so the failure is a clear message, not a mid-build one.
appimage_prereqs() {
  command -v file >/dev/null 2>&1 \
    || die "'file' not found — appimagetool requires it (apt install file / dnf install file / …)"
}

build_appimage() {
  local appdir="$WORK/appimage" out="$OUT_DIR/seance-linux-$FLUTTER_ARCH.AppImage"
  install -d "$appdir/usr"
  cp -a "$DEBROOT/usr/." "$appdir/usr/"
  rm -rf "${appdir:?}/usr/bin"   # the deb's wrapper hardcodes /usr/lib — dead
                               # weight here; AppRun is the entry point

  write_desktop_file "$appdir/seance.desktop" "AppRun"
  # appimagetool wants the icon named after Icon= at the AppDir root, plus
  # .DirIcon for file managers.
  make_icon "$MASTER_ICON" "$appdir/seance.png" 512 \
    || cp "$MASTER_ICON" "$appdir/seance.png"
  cp "$appdir/seance.png" "$appdir/.DirIcon"

  cat > "$appdir/AppRun" <<'EOF'
#!/bin/sh
# AppImages mount read-only at a random path; resolve through symlinks so the
# runner's $ORIGIN-relative lib/ and data/ lookups work.
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/lib/seance/seance_app" "$@"
EOF
  chmod 755 "$appdir/AppRun"

  # appimagetool: a pinned release asset, cached across runs. The tool's arch
  # is the BUILD host's (it embeds the target runtime per ARCH=, so an x86_64
  # tool packages arm64 images fine). APPIMAGETOOL may be a path or a URL.
  resolve_appimagetool   # sets APPIMAGE_TOOL
  appimage_prereqs
  local tool="$APPIMAGE_TOOL"

  echo "-- appimagetool → $(basename "$out")"
  # No AppStream metainfo yet — pass --no-appstream rather than shipping an
  # empty one. EXTRACT_AND_RUN keeps the tool working where FUSE can't mount
  # (CI containers, this dev container, …).
  if ARCH="$APPIMAGE_ARCH" APPIMAGE_EXTRACT_AND_RUN=1 "$tool" \
      --no-appstream "$appdir" "$out" >/dev/null 2>&1; then
    :
  else
    # Retry once with output visible so the failure is diagnosable.
    ARCH="$APPIMAGE_ARCH" APPIMAGE_EXTRACT_AND_RUN=1 "$tool" \
      --no-appstream "$appdir" "$out"
  fi
}

mkdir -p "$OUT_DIR"
if $HAVE_DPKG; then
  mv "$WORK/$DEB_NAME" "$OUT_DIR/"
  echo "✓ $OUT_DIR/$DEB_NAME"
fi

if [[ "$APPIMAGE_MODE" != "skip" ]]; then
  if build_appimage; then
    echo "✓ $OUT_DIR/seance-linux-$FLUTTER_ARCH.AppImage"
  elif [[ "$APPIMAGE_MODE" == "best-effort" ]]; then
    echo "!! package-linux: AppImage build failed (best-effort mode — continuing with the .deb only)" >&2
  else
    die "AppImage build failed"
  fi
fi
