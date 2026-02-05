#!/bin/bash
# build-k9s.sh
# ─────────────────────────────────────────────────────────────
# Build k9s from source with a Go version that fixes four stdlib CVEs.
#
# k9s v0.50.18 (latest as of 2026-02-05) ships compiled against Go 1.25.1.
# The following stdlib CVEs are fixed in Go 1.25.6:
#   CVE-2025-58183  archive/tar  – unbounded allocation on GNU sparse maps
#   CVE-2025-61726  net/url      – memory exhaustion in query parsing
#   CVE-2025-61728  archive/zip  – excessive CPU building archive index
#   CVE-2025-61729  crypto/x509  – DoS via excessive resource consumption
#
# Once k9s publishes a release built with Go >= 1.25.6, comment out the
# source-build section below and uncomment the binary-download section.
# ─────────────────────────────────────────────────────────────

set -euo pipefail

K9S_TAG="v0.50.18"

# ── Original binary download (uncomment when k9s ships a clean release) ──
# K9S_SHA256="0b697ed4aa80997f7de4deeed6f1fba73df191b28bf691b1f28d2f45fa2a9e9b"
# mkdir -p /tmp/k9s
# curl -sL "https://github.com/derailed/k9s/releases/download/${K9S_TAG}/k9s_Linux_amd64.tar.gz" -o /tmp/k9s.tar.gz
# echo "${K9S_SHA256}  /tmp/k9s.tar.gz" | sha256sum -c - || { echo "ERROR: k9s checksum verification failed"; exit 1; }
# tar xzf /tmp/k9s.tar.gz -C /tmp/k9s
# /tmp/k9s/k9s version || { echo "ERROR: k9s binary validation failed"; exit 1; }
# install -m 0755 /tmp/k9s/k9s /usr/bin/k9s
# rm -rf /tmp/k9s /tmp/k9s.tar.gz
# exit 0

# ── Source build (active until k9s ships a release with Go >= 1.25.6) ────
K9S_REPO="https://github.com/derailed/k9s.git"
REQUIRED_GO="1.25.6"
BUILD_DIR="/tmp/k9s-src"

echo "=== Building k9s ${K9S_TAG} from source (Go stdlib CVE patch) ==="

# ── 1. Install build-time dependencies ──────────────────────
dnf5 install -y golang make

# ── 2. Verify installed Go is adequate ───────────────────────
GO_VER=$(go version | awk '{print $3}' | sed 's/go//')
echo "Installed Go: ${GO_VER}"

awk -v got="${GO_VER}" -v need="${REQUIRED_GO}" 'BEGIN {
    split(got, a, ".")
    split(need, b, ".")
    if (a[1]+0 < b[1]+0 ||
       (a[1]+0 == b[1]+0 && a[2]+0 < b[2]+0) ||
       (a[1]+0 == b[1]+0 && a[2]+0 == b[2]+0 && a[3]+0 < b[3]+0)) {
        print "ERROR: Go " got " < required " need > "/dev/stderr"
        exit 1
    }
}'

# ── 3. Clone at the exact tag ────────────────────────────────
git clone --depth 1 --branch "${K9S_TAG}" "${K9S_REPO}" "${BUILD_DIR}"
cd "${BUILD_DIR}"

# ── 4. Patch go.mod ─────────────────────────────────────────
# Update the 'go' directive so the module declares the version we are
# actually compiling with.  Remove any 'toolchain' pin that would otherwise
# cause Go to try downloading a different toolchain.
sed -i "s/^go [0-9.]*$/go ${REQUIRED_GO}/" go.mod
sed -i '/^toolchain /d' go.mod

# ── 5. Build ─────────────────────────────────────────────────
# GOTOOLCHAIN=local prevents Go from downloading a pinned toolchain
# even if go.mod or GOTOOLCHAIN env would otherwise request one.
export GOTOOLCHAIN=local
make build

# ── 6. Smoke-test and install ────────────────────────────────
./execs/k9s version || { echo "ERROR: k9s binary validation failed"; exit 1; }
install -m 0755 ./execs/k9s /usr/bin/k9s

# ── 7. Remove build artifacts and build-time packages ───────
cd /
rm -rf "${BUILD_DIR}"
dnf5 remove -y golang make
dnf5 clean all

echo "=== k9s ${K9S_TAG} installed (compiled with Go ${GO_VER}) ==="
