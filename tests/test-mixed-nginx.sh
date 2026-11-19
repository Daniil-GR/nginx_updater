#!/bin/sh
# Non-destructive preflight tests for hosts with mixed system and Docker nginx.
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' 0 1 2 15
sed '/^case "\${1:---auto}" in/,$d' nginx-updater.sh > "$TEST_DIR/library.sh"
LIB="$TEST_DIR/library.sh"
export LIB

run_preflight() (
    MOCK_DOCKER=$1
    MOCK_ORIGIN=$2
    MOCK_SYSTEM=$3
    MOCK_MODE=$4
    . "$LIB"
    nginx_pids() { echo "$$"; }
    nginx_process_origin() { echo "$MOCK_ORIGIN"; }
    has_docker_nginx() { [ "$MOCK_DOCKER" = yes ]; }
    runtime_overview() { :; }
    docker() {
        case "$1" in
            info|ps) return 0 ;;
            *) return 1 ;;
        esac
    }
    systemctl() {
        [ "$1" = is-active ] && [ "$2" = --quiet ] && [ "$3" = nginx ] &&
        [ "$MOCK_SYSTEM" = yes ]
    }
    ss() { :; }
    runtime_preflight "$MOCK_MODE"
    printf 'PREFLIGHT_OK\n'
)
# Lithuania: active system nginx on CDN IP + nginx in Docker on Selfsteal IP.
OUT=$(run_preflight yes container yes update)
printf '%s\n' "$OUT" | grep -qx 'PREFLIGHT_OK'
printf '%s\n' "$OUT" | grep -q 'ТОЛЬКО активный системный nginx'

# New York: inactive system nginx, active Docker nginx. Must not update unused APT package.
if run_preflight yes container no update > "$TEST_DIR/inactive.out" 2>&1; then
    echo 'Expected inactive system to be blocked' >&2; exit 1
fi
grep -q 'не активен' "$TEST_DIR/inactive.out"

# APT installation must be blocked when another nginx in Docker exists.
if run_preflight yes container no install > "$TEST_DIR/install.out" 2>&1; then
    echo 'Expected duplicate installation to be blocked' >&2; exit 1
fi
grep -q 'Не устанавливаю второй системный nginx' "$TEST_DIR/install.out"

# Unknown/custom nginx process must block even when nginx.service is running.
if run_preflight no external yes update > "$TEST_DIR/external.out" 2>&1; then
    echo 'Expected foreign nginx process to be blocked' >&2; exit 1
fi
grep -q 'вне nginx.service/Docker' "$TEST_DIR/external.out"

# Ordinary APT nginx (only system process) allowed.
OUT=$(run_preflight no systemd yes update)
printf '%s\n' "$OUT" | grep -qx 'PREFLIGHT_OK'
printf 'mixed nginx preflight tests passed\n'
