#!/bin/sh
# Offline tests: mock systemctl, docker, and APT; never touch production services.
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' 0 1 2 15
sed '/^case "\${1:---auto}" in/,$d' nginx-updater.sh > "$TEST_DIR/library.sh"
LIB="$TEST_DIR/library.sh"
export LIB

run_auto() (
    MOCK_APT=$1
    MOCK_SYSTEM=$2
    MOCK_DOCKER=$3
    . "$LIB"
    need_root() { :; }
    nginx_installed() { [ "$MOCK_APT" = yes ]; }
    nginx_pids() { :; }
    runtime_overview() { :; }
    systemctl() {
        if [ "$1" = is-active ] && [ "$2" = --quiet ] && [ "$3" = nginx ]; then
            [ "$MOCK_SYSTEM" = yes ]
        else
            return 1
        fi
    }
    docker() {
        case "$1" in
            info) return 0 ;;
            ps) printf '%b' "$MOCK_DOCKER" ;;
            *) return 1 ;;
        esac
    }
    docker_update() { echo "SELECTED_DOCKER=$1"; }
    update_nginx() { echo "SELECTED_APT=$1"; }
    auto_update
)

# APT only, no Docker.
OUT=$(run_auto yes yes '')
echo "$OUT" | grep -qx 'SELECTED_APT=stable'

# Docker active + inactive but installed host nginx (New York setup).
OUT=$(run_auto yes no 'nginx-selfsteal|nginx:1.30.7-alpine\n')
echo "$OUT" | grep -qx 'SELECTED_DOCKER=nginx-selfsteal'
if echo "$OUT" | grep -q '^SELECTED_APT='; then exit 1; fi

# Docker active and no APT nginx.
OUT=$(run_auto no no 'nginx-selfsteal|nginx:1.30.7-alpine\n')
echo "$OUT" | grep -qx 'SELECTED_DOCKER=nginx-selfsteal'

# Two Docker nginx instances: fail safely.
if run_auto yes no 'nginx-a|nginx:1.30.7-alpine\nnginx-b|nginx:1.30.7-alpine\n' > "$TEST_DIR/multi.out" 2>&1; then
    echo 'ERROR: expected ambiguity failure for two containers' >&2; exit 1
fi
grep -q 'несколько nginx-контейнеров' "$TEST_DIR/multi.out"

# Host nginx and Docker nginx simultaneously: fail safely.
if run_auto yes yes 'nginx-a|nginx:1.30.7-alpine\n' > "$TEST_DIR/both.out" 2>&1; then
    echo 'ERROR: expected ambiguity failure for two active implementations' >&2; exit 1
fi
grep -q 'и nginx.service, и nginx в Docker' "$TEST_DIR/both.out"

# No nginx: do not install anything.
if run_auto no no '' > "$TEST_DIR/none.out" 2>&1; then
    echo 'ERROR: expected failure when no nginx exists' >&2; exit 1
fi
grep -q 'Не найден однозначный nginx' "$TEST_DIR/none.out"

echo 'auto selection smoke tests passed'
