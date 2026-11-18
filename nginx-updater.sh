#!/bin/sh
# nginx_updater: safe APT-based installer/updater for official nginx packages.
set -eu

VERSION=1.0.0
BACKUP_ROOT=/var/backups/nginx-updater
KEYRING=/usr/share/keyrings/nginx-archive-keyring.gpg
REPO_LIST=/etc/apt/sources.list.d/nginx.list
PIN_FILE=/etc/apt/preferences.d/99nginx
SIGNING_KEY_URL=https://nginx.org/keys/nginx_signing.key
EXPECTED_FINGERPRINT=573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62

info() { printf '[nginx-updater] %s\n' "$*"; }
fail() { printf '[nginx-updater] ОШИБКА: %s\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || fail 'Для этой команды нужен root. Запусти через sudo sh nginx-updater.sh ...'; }
nginx_installed() { dpkg-query -W -f='${Status}' nginx 2>/dev/null | grep -qx 'install ok installed'; }

check_platform() {
    [ -r /etc/os-release ] || fail 'Не удалось определить ОС.'
    . /etc/os-release
    OS_ID=$ID
    CODENAME=${VERSION_CODENAME:-}
    case "$OS_ID:$CODENAME" in
        ubuntu:jammy|ubuntu:noble|ubuntu:resolute|debian:bookworm|debian:trixie) ;;
        *) fail "Поддерживаются Ubuntu 22.04/24.04/26.04 и Debian 12/13; обнаружено $OS_ID:$CODENAME" ;;
    esac
    [ "$(dpkg --print-architecture)" = amd64 ] || [ "$(dpkg --print-architecture)" = arm64 ] || fail 'Поддерживаются только amd64 и arm64.'
}

branch_from_repo() {
    if [ -r "$REPO_LIST" ] && grep -q 'nginx.org/packages/mainline/' "$REPO_LIST"; then
        printf mainline
    else
        printf stable
    fi
}

status() {
    info "nginx_updater $VERSION"
    if command -v nginx >/dev/null 2>&1; then nginx -v 2>&1; else info 'nginx не найден в PATH'; fi
    if nginx_installed; then
        dpkg-query -W -f='Пакет: ${binary:Package} ${Version}\n' nginx
    else
        info 'Системный пакет nginx не установлен'
    fi
    if command -v apt-cache >/dev/null 2>&1; then
        apt-cache policy nginx | sed -n '1,12p'
    fi
    if command -v systemctl >/dev/null 2>&1; then
        info "Служба: $(systemctl is-active nginx 2>/dev/null || true)"
        info "Автозапуск: $(systemctl is-enabled nginx 2>/dev/null || true)"
    fi
    info "Ветка репозитория: $(branch_from_repo) (если настроен через nginx-updater)"
}

validate() {
    command -v nginx >/dev/null 2>&1 || fail 'nginx не установлен'
    nginx -t
    info 'Активные конфигурационные файлы:'
    nginx -T 2>&1 | grep '^# configuration file ' || true
}

diagnose() {
    validate
    info 'Настройки HTTP/2:'
    nginx -T 2>&1 | grep -nE 'listen .*http2|^[[:space:]]*http2[[:space:]]+(on|off)' || true
    info 'Прослушиваемые порты nginx:'
    if command -v ss >/dev/null 2>&1; then ss -lntp | grep nginx || true; fi
    info 'Загруженные динамические модули:'
    nginx -T 2>&1 | grep -E '^[[:space:]]*load_module ' || true
}

backup() {
    need_root
    mkdir -p "$BACKUP_ROOT"
    BACKUP_DIR="$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir -p "$BACKUP_DIR"
    if [ -d /etc/nginx ]; then cp -a /etc/nginx "$BACKUP_DIR/nginx"; fi
    if [ -f "$REPO_LIST" ]; then cp -a "$REPO_LIST" "$BACKUP_DIR/nginx.list"; fi
    if [ -f "$PIN_FILE" ]; then cp -a "$PIN_FILE" "$BACKUP_DIR/99nginx"; fi
    if [ -f "$KEYRING" ]; then cp -a "$KEYRING" "$BACKUP_DIR/keyring.gpg"; fi
    if command -v nginx >/dev/null 2>&1; then
        nginx -T > "$BACKUP_DIR/full-config.txt" 2>&1 || true
    fi
    dpkg-query -W -f='${binary:Package} ${Version}\n' 'nginx*' > "$BACKUP_DIR/packages.txt" 2>/dev/null || true
    info "Резервная копия: $BACKUP_DIR"
}

check_modules_before_switch() {
    if ! nginx_installed; then return 0; fi
    if [ -r "$REPO_LIST" ] && grep -q 'nginx.org/packages/' "$REPO_LIST"; then return 0; fi
    MODULE_PACKAGES=$(dpkg-query -W -f='${binary:Package} ${Status}\n' 'libnginx-mod-*' 2>/dev/null | awk '$0 ~ /install ok installed/ {print $1}' || true)
    if [ -n "$MODULE_PACKAGES" ]; then
        fail "Обнаружены модули Ubuntu ($MODULE_PACKAGES). Автоматическая смена поставщика запрещена: нужна ручная проверка совместимости."
    fi
    if nginx -T 2>&1 | grep -Eq '^[[:space:]]*load_module[[:space:]]'; then
        fail 'Обнаружены динамические модули load_module. Смена поставщика требует ручной проверки.'
    fi
}

configure_repo() {
    BRANCH=$1
    check_platform
    info "Настройка nginx.org ($BRANCH) для $OS_ID/$CODENAME"
    if [ -f "$REPO_LIST" ] && ! grep -q 'nginx.org/packages/' "$REPO_LIST"; then
        fail "$REPO_LIST существует и принадлежит другому источнику. Не перезаписываю его."
    fi
    CONFLICTS=$(grep -rl 'nginx.org/packages/' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | grep -v -x "$REPO_LIST" || true)
    [ -z "$CONFLICTS" ] || fail "Другие источники nginx.org уже подключены: $CONFLICTS"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg
    TEMP_KEY=$(mktemp)
    trap 'rm -f "$TEMP_KEY"' EXIT HUP INT TERM
    curl --fail --silent --show-error --location --retry 3 "$SIGNING_KEY_URL" -o "$TEMP_KEY"
    if ! gpg --batch --show-keys --with-colons "$TEMP_KEY" 2>/dev/null | grep -q "^fpr:::::::::$EXPECTED_FINGERPRINT:"; then
        fail 'Отпечаток ключа nginx.org не совпадает с ожидаемым.'
    fi
    mkdir -p /usr/share/keyrings
    gpg --batch --yes --dearmor -o "$KEYRING" "$TEMP_KEY"
    chmod 644 "$KEYRING"
    rm -f "$TEMP_KEY"
    trap - EXIT HUP INT TERM
    BASE_URL="https://nginx.org/packages/$OS_ID"
    [ "$BRANCH" = mainline ] && BASE_URL="https://nginx.org/packages/mainline/$OS_ID"
    printf 'deb [signed-by=%s] %s %s nginx\n' "$KEYRING" "$BASE_URL" "$CODENAME" > "$REPO_LIST"
    cat > "$PIN_FILE" <<'EOF'
Package: nginx
Pin: origin nginx.org
Pin-Priority: 900
EOF
    apt-get update
    info 'Официальный репозиторий подключён. Системные конфигурации nginx не изменены.'
}

update_nginx() {
    need_root
    BRANCH=$1
    check_platform
    if command -v nginx >/dev/null 2>&1 && ! nginx_installed; then
        fail 'Найден nginx, установленный не через dpkg. Автоматическое обновление запрещено.'
    fi
    if nginx_installed; then
        nginx -t || fail 'Текущая конфигурация содержит ошибки. Сначала исправь nginx -t.'
    fi
    check_modules_before_switch
    if apt-mark showhold | grep -qx nginx; then fail 'nginx находится на hold (apt-mark). Сними блокировку вручную.'; fi
    WAS_ACTIVE=no
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then WAS_ACTIVE=yes; fi
    BEFORE_SITES=0
    if nginx_installed; then
        BEFORE_SITES=$(nginx -T 2>&1 | grep -c '^# configuration file /etc/nginx/sites-enabled/' || true)
    fi
    backup
    configure_repo "$BRANCH"
    CANDIDATE=$(apt-cache policy nginx | awk '/Candidate:/ {print $2; exit}')
    [ -n "$CANDIDATE" ] && [ "$CANDIDATE" != '(none)' ] || fail 'Пакет nginx недоступен в APT.'
    if ! apt-cache madison nginx | awk -v candidate="$CANDIDATE" '$3 == candidate && /nginx.org\/packages\// {found=1} END {exit !found}'; then
        fail "Кандидат $CANDIDATE получен не из nginx.org. Установка отменена."
    fi
    if nginx_installed; then
        INSTALLED=$(dpkg-query -W -f='${Version}' nginx)
        if dpkg --compare-versions "$CANDIDATE" lt "$INSTALLED"; then
            fail "Кандидат $CANDIDATE старее установленного $INSTALLED. Автоматический downgrade запрещён."
        fi
        if [ "$CANDIDATE" = "$INSTALLED" ]; then
            info "Уже установлена актуальная версия $INSTALLED; пакеты не менялись."
            validate
            return 0
        fi
    fi
    PLAN=$(mktemp)
    trap 'rm -f "$PLAN"' EXIT HUP INT TERM
    apt-get -s install nginx > "$PLAN" || fail 'Предварительная проверка APT завершилась ошибкой.'
    cat "$PLAN"
    REMOVALS=$(awk '/^Remv / && $2 != "nginx-common" {print $2}' "$PLAN")
    [ -z "$REMOVALS" ] || fail "APT хочет удалить посторонние пакеты: $REMOVALS. Установка отменена."
    rm -f "$PLAN"
    trap - EXIT HUP INT TERM
    info "Устанавливаю nginx $CANDIDATE ($BRANCH). Сохраняю локальные конфигурации."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::="--force-confold" nginx
    nginx -t || fail "После установки nginx -t выдаёт ошибку. Резерв: $BACKUP_DIR. Службу не перезапускаю."
    AFTER_SITES=$(nginx -T 2>&1 | grep -c '^# configuration file /etc/nginx/sites-enabled/' || true)
    if [ "$AFTER_SITES" -lt "$BEFORE_SITES" ]; then
        fail "После обновления стало меньше активных sites-enabled ($BEFORE_SITES -> $AFTER_SITES). Резерв: $BACKUP_DIR. Службу не перезапускаю."
    fi
    if command -v systemctl >/dev/null 2>&1 && [ "$WAS_ACTIVE" = yes ]; then
        systemctl daemon-reload
        systemctl restart nginx || fail 'nginx не запустился. Проверь journalctl -u nginx -n 100.'
        systemctl is-active --quiet nginx || fail 'nginx неактивен после обновления.'
    fi
    info "Успешно: $(nginx -v 2>&1). Резервная копия: $BACKUP_DIR"
    if [ "$WAS_ACTIVE" = no ]; then info "Ранее служба была остановлена; явный запуск не выполнялся. Текущий статус: $(systemctl is-active nginx 2>/dev/null || true)"; fi
    info 'Проверь HTTPS на реальных доменах и доступность прокси извне.'
}

check_updates() {
    need_root
    apt-get update
    status
}

menu() {
    while :; do
        printf '\n===== nginx_updater %s =====\n' "$VERSION"
        printf '1) Статус nginx и APT\n2) Проверить доступные обновления\n3) Обновить/установить nginx stable\n4) Обновить/установить nginx mainline\n5) Проверить nginx -t и подключённые конфиги\n6) Создать резервную копию\n7) Показать резервные копии\n8) Диагностика HTTP/2, портов и модулей\n0) Выход\nВыбор: '
        read -r CHOICE || return 0
        case "$CHOICE" in
            1) status ;;
            2) check_updates ;;
            3) update_nginx stable ;;
            4) printf 'Для перехода на mainline напиши MAINLINE: '; read -r CONFIRM || return 0; [ "$CONFIRM" = MAINLINE ] && update_nginx mainline || info 'Отменено' ;;
            5) validate ;;
            6) backup ;;
            7) ls -lht "$BACKUP_ROOT" 2>/dev/null || info 'Резервных копий пока нет' ;;
            8) diagnose ;;
            0) return 0 ;;
            *) info 'Неизвестная команда' ;;
        esac
    done
}

usage() {
    cat <<'EOF'
nginx_updater — автоматическая установка/обновление nginx через nginx.org.
Запуск: sudo sh nginx-updater.sh [команда]
  --auto       Обновить nginx; сохранить текущую ветку nginx.org, иначе stable (по умолчанию)
  --stable     Установить/обновить официальный nginx stable
  --mainline   Установить/обновить официальный nginx mainline
  --menu       Интерактивное меню
  --status     Показать версии, APT и состояние службы
  --check      Обновить индексы APT и показать доступные версии
  --test       nginx -t и список загруженных конфигураций
  --diagnose   Проверка HTTP/2, модулей и прослушиваемых портов
  --backup     Создать резервную копию /etc/nginx
  --help       Показать справку

Внимание: nginx в Docker, NGINX Plus и сборки из исходников не обновляются.
Ubuntu: 22.04, 24.04, 26.04; Debian: 12, 13. Режим --auto не обновляет другие пакеты ОС,
кроме необходимых зависимостей. Установка может кратковременно прервать соединения.
EOF
}

case "${1:---auto}" in
    --auto) update_nginx "$(branch_from_repo)" ;;
    --stable) update_nginx stable ;;
    --mainline) update_nginx mainline ;;
    --menu) menu ;;
    --status) status ;;
    --check) check_updates ;;
    --test) validate ;;
    --diagnose) diagnose ;;
    --backup) backup ;;
    --help|-h) usage ;;
    *) usage; exit 2 ;;
esac
