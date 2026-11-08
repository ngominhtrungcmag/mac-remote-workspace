#!/usr/bin/env bash
# Builds FreeRDP v3 + OpenSSL 3 (static, from source) into vendor/FreeRDP.xcframework.
# See docs/adr/embedded-rdp-freerdp.md.
#
# Env: ARCHS="arm64 x86_64" (default; override to build a single architecture)
# No sudo / brew needed: if cmake or ninja are missing they are installed into a venv under the
# (gitignored) build dir via pip.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/vendor/.build"
OUTPUT_DIR="${REPO_ROOT}/vendor"
FREERDP_VERSION="3.10.2"
FREERDP_COMMIT="ea2a3ee1b6ee622171669df3814aeca70a496c31"
OPENSSL_VERSION="3.4.1"
OPENSSL_SHA256="002a2d6b30b58bf4bea46c43bdd96365aaf8daa6c428782aa4feee06da197df3"
ARCHS=(${ARCHS:-arm64 x86_64})
MIN_MACOS="14.0"
JOBS="$(sysctl -n hw.ncpu)"

for t in git xcrun curl python3; do command -v "$t" >/dev/null || { echo "missing: $t" >&2; exit 1; }; done
mkdir -p "${BUILD_DIR}"

if ! command -v cmake >/dev/null || ! command -v ninja >/dev/null; then
    echo "cmake/ninja not found; bootstrapping into ${BUILD_DIR}/venv"
    [ -x "${BUILD_DIR}/venv/bin/cmake" ] || {
        python3 -m venv "${BUILD_DIR}/venv"
        "${BUILD_DIR}/venv/bin/pip" install -q cmake ninja
    }
    export PATH="${BUILD_DIR}/venv/bin:${PATH}"
fi

SDK="$(xcrun --sdk macosx --show-sdk-path)"

# --- sources ------------------------------------------------------------------
OSSL_SRC="${BUILD_DIR}/openssl-${OPENSSL_VERSION}"
if [ ! -d "${OSSL_SRC}" ]; then
    base="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}"
    curl -fsSL -o "${BUILD_DIR}/openssl.tgz" "${base}/openssl-${OPENSSL_VERSION}.tar.gz"
    echo "${OPENSSL_SHA256}  ${BUILD_DIR}/openssl.tgz" | shasum -a 256 -c -
    tar -xzf "${BUILD_DIR}/openssl.tgz" -C "${BUILD_DIR}"
fi
FRDP_SRC="${BUILD_DIR}/FreeRDP-${FREERDP_VERSION}"
[ -d "${FRDP_SRC}" ] || git clone -q --depth 1 --branch "${FREERDP_VERSION}" https://github.com/FreeRDP/FreeRDP.git "${FRDP_SRC}"
[ "$(git -C "${FRDP_SRC}" rev-parse HEAD)" = "${FREERDP_COMMIT}" ] || { echo "FreeRDP commit mismatch" >&2; exit 1; }

# --- per-arch build -----------------------------------------------------------
for ARCH in "${ARCHS[@]}"; do
    PREFIX="${BUILD_DIR}/install-${ARCH}"
    OSSL_PREFIX="/usr/local/mrw-openssl"
    OSSL_STAGE="${BUILD_DIR}/stage-${ARCH}${OSSL_PREFIX}"
    [ -f "${PREFIX}/.done-neutral-paths" ] && continue
    rm -rf "${PREFIX}" "${BUILD_DIR}/stage-${ARCH}" "${BUILD_DIR}/ossl-${ARCH}" "${BUILD_DIR}/build-${ARCH}"
    mkdir -p "${PREFIX}" "${BUILD_DIR}/ossl-${ARCH}"

    case "${ARCH}" in arm64) OT=darwin64-arm64-cc ;; x86_64) OT=darwin64-x86_64-cc ;; *) echo "bad arch" >&2; exit 1 ;; esac
    ( cd "${BUILD_DIR}/ossl-${ARCH}" &&
      "${OSSL_SRC}/Configure" "${OT}" no-shared no-tests no-apps no-docs no-legacy no-autoload-config \
          --prefix="${OSSL_PREFIX}" --openssldir=/etc/ssl --libdir=lib "-mmacosx-version-min=${MIN_MACOS}" &&
      make -j"${JOBS}" build_libs >/dev/null && make DESTDIR="${BUILD_DIR}/stage-${ARCH}" install_dev >/dev/null )

    cmake -G Ninja -B "${BUILD_DIR}/build-${ARCH}" -S "${FRDP_SRC}" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_OSX_SYSROOT="${SDK}" -DCMAKE_OSX_DEPLOYMENT_TARGET="${MIN_MACOS}" \
        -DCMAKE_OSX_ARCHITECTURES="${ARCH}" -DCMAKE_INSTALL_PREFIX=/usr/local/mrw-freerdp \
        -DCMAKE_PREFIX_PATH="${PREFIX}" -DOPENSSL_ROOT_DIR="${OSSL_STAGE}" -DOPENSSL_USE_STATIC_LIBS=ON \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
        -DWITH_CLIENT=ON -DWITH_CLIENT_COMMON=ON -DWITH_CLIENT_SDL=OFF -DWITH_CLIENT_MAC=OFF -DWITH_CLIENT_CHANNELS=ON \
        -DWITH_SERVER=OFF -DWITH_SHADOW=OFF -DWITH_PROXY=OFF -DWITH_SAMPLE=OFF -DWITH_MANPAGES=OFF \
        -DWITH_X11=OFF -DWITH_WAYLAND=OFF -DWITH_CUPS=OFF -DWITH_PCSC=OFF -DWITH_PULSE=OFF -DWITH_ALSA=OFF \
        -DWITH_OSS=OFF -DWITH_FUSE=OFF -DWITH_CAIRO=OFF -DWITH_SWSCALE=OFF -DWITH_FFMPEG=OFF -DWITH_VIDEO_FFMPEG=OFF \
        -DWITH_OPENH264=OFF -DWITH_KRB5=OFF -DWITH_MBEDTLS=OFF -DWITH_OPENSSL=ON -DWITH_JPEG=OFF \
        -DWITH_JSON_DISABLED=ON -DWITH_WEBVIEW=OFF -DWITH_AAD=OFF -DWITH_FREERDP_DEPRECATED_COMMANDLINE=OFF \
        -DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_MD5=ON -DWITH_INTERNAL_RC4=ON \
        -DWITH_SIMD=ON -DWITH_NEON=ON \
        -DCHANNEL_PRINTER=OFF -DCHANNEL_SMARTCARD=OFF -DCHANNEL_URBDRC=OFF -DCHANNEL_TSMF=OFF \
        -DCHANNEL_RDPSND=OFF -DCHANNEL_AUDIN=OFF -DCHANNEL_PARALLEL=OFF -DCHANNEL_SERIAL=OFF \
        -DCHANNEL_DRIVE=ON -DCHANNEL_RAIL=OFF -DCHANNEL_REMDESK=OFF -DCHANNEL_RDPEI=ON \
        -DCHANNEL_VIDEO=OFF -DCHANNEL_GEOMETRY=OFF -DCHANNEL_ECHO=OFF -DCHANNEL_LOCATION=OFF \
        -DCHANNEL_ENCOMSP=OFF -DCHANNEL_SSHAGENT=OFF -DCHANNEL_RDPDR=ON -DCHANNEL_RDP2TCP=OFF \
        -DCHANNEL_DISP=ON -DCHANNEL_CLIPRDR=ON -DCHANNEL_RDPGFX=ON -DCHANNEL_DRDYNVC=ON
    cmake --build "${BUILD_DIR}/build-${ARCH}" --parallel "${JOBS}"
    # Install via a staging DESTDIR so no build-machine path is baked into the binary.
    rm -rf "${BUILD_DIR}/fstage-${ARCH}"
    DESTDIR="${BUILD_DIR}/fstage-${ARCH}" cmake --install "${BUILD_DIR}/build-${ARCH}"
    cp -R "${BUILD_DIR}/fstage-${ARCH}/usr/local/mrw-freerdp/." "${PREFIX}/"
    touch "${PREFIX}/.done-neutral-paths"
done

# --- merge static libs per arch, lipo, xcframework ----------------------------
MERGED=()
for ARCH in "${ARCHS[@]}"; do
    P="${BUILD_DIR}/install-${ARCH}"
    libtool -static -o "${BUILD_DIR}/libFreeRDPAll-${ARCH}.a" "${P}"/lib/*.a "${BUILD_DIR}/stage-${ARCH}/usr/local/mrw-openssl/lib/"*.a
    MERGED+=("${BUILD_DIR}/libFreeRDPAll-${ARCH}.a")
done
lipo -create "${MERGED[@]}" -output "${BUILD_DIR}/libFreeRDPAll.a"

HDR="${BUILD_DIR}/headers"
rm -rf "${HDR}"; mkdir -p "${HDR}"
P0="${BUILD_DIR}/install-${ARCHS[0]}/include"
cp -R "${P0}/freerdp3/." "${P0}/winpr3/." "${HDR}/"  # flat: <freerdp/..>, <winpr/..>
cat > "${HDR}/module.modulemap" <<MM
module CFreeRDP [system] {
    header "shim.h"
    link "FreeRDPAll"
    link "z"
    link framework "Security"
    link framework "CoreFoundation"
    link framework "SystemConfiguration"
    export *
}
MM
cat > "${HDR}/shim.h" <<'H'
#include <freerdp/freerdp.h>
#include <freerdp/settings.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/channels/channels.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/disp.h>
#include <freerdp/client/cliprdr.h>
H

rm -rf "${OUTPUT_DIR}/FreeRDP.xcframework"
xcodebuild -create-xcframework -library "${BUILD_DIR}/libFreeRDPAll.a" -headers "${HDR}" \
    -output "${OUTPUT_DIR}/FreeRDP.xcframework"
echo "OK: ${OUTPUT_DIR}/FreeRDP.xcframework"
