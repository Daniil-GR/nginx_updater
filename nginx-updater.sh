#!/bin/sh
# nginx_updater: safe APT-based installer/updater for official nginx packages.
set -eu

VERSION=1.2.0
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


# Изучаем работающие nginx до ЛЮБОЙ установки или обновления.
# На хосте /proc/<pid>/exe у контейнера тоже может быть /usr/sbin/nginx:
# только readlink недостаточно. Проверяем cgroup и список Docker.
nginx_pids() {
    if command -v ps >/dev/null 2>&1; then
        ps -eo pid=,comm= | awk '$2=="nginx" {print $1}'
    fi
}

nginx_process_origin() {
    PID=$1
    CG=$(cat "/proc/$PID/cgroup" 2>/dev/null || true)
    case "$CG" in
        *docker-*|*/docker/*|*containerd*|*kubepods*|*libpod*|*podman*) printf container ;;
        */nginx.service|*/nginx.service/*) printf systemd ;;
        *) printf external ;;
    esac
}

has_non_system_nginx() {
    for PID in $(nginx_pids); do
        [ -d "/proc/$PID" ] || continue
        ORIGIN=$(nginx_process_origin "$PID")
        [ "$ORIGIN" = systemd ] || return 0
    done
    return 1
}

has_docker_nginx() {
    if command -v docker >/dev/null 2>&1; then
        docker ps --format '{{.Names}}|{{.Image}}' 2>/dev/null | grep -iq nginx
    else
        return 1
    fi
}

docker_overview() {
    if ! command -v docker >/dev/null 2>&1; then
        info 'Docker CLI не найден.'
        return 0
    fi
    info 'Запущенные Docker-контейнеры, связанные с nginx:'
    CONTAINERS=$(docker ps --format '{{.Names}}|{{.Image}}' 2>/dev/null | grep -i nginx || true)
    if [ -z "$CONTAINERS" ]; then
        info 'Контейнеров с nginx в имени/образе не найдено.'
        return 0
    fi
    printf '%s\n' "$CONTAINERS" | while IFS='|' read -r NAME IMAGE; do
        [ -n "$NAME" ] || continue
        printf '  %s — %s\n' "$NAME" "$IMAGE"
        docker exec "$NAME" nginx -v 2>&1 | sed 's/^/    /' || true
        # Этикетки Compose помогают определить, откуда следует обновлять контейнер.
        META=$(docker inspect -f 'project={{index .Config.Labels "com.docker.compose.project"}} service={{index .Config.Labels "com.docker.compose.service"}}' "$NAME" 2>/dev/null || true)
        [ -z "$META" ] || printf '    %s\n' "$META"
    done
    info 'APT не обновляет контейнерные образы. Для обновления Docker требуется отдельное изменение образа/Compose и пересоздание контейнера.'
}


# Обновляем только явно выбранный контейнер Compose, не затрагивая прочие сервисы.
# Автоматически разрешается последняя стабильная Alpine-версия официального nginx,
# но в Compose сохраняется точный тег nginx:X.Y.Z-alpine вместо плавающего stable.
docker_update_rollback() {
    info "Обновление контейнера не удалось. Пытаюсь вернуть исходный Compose и образ $DOCKER_OLD_IMAGE."
    if cp -p "$DOCKER_BACKUP/original-compose.yml" "$DOCKER_COMPOSE_FILE" &&
       docker compose -p "$DOCKER_PROJECT" --project-directory "$DOCKER_WORKDIR" -f "$DOCKER_COMPOSE_FILE" config -q &&
       docker compose -p "$DOCKER_PROJECT" --project-directory "$DOCKER_WORKDIR" -f "$DOCKER_COMPOSE_FILE" up -d --no-deps --force-recreate "$DOCKER_SERVICE" &&
       docker exec "$DOCKER_NAME" nginx -t; then
        info "Откат Compose выполнен, старый nginx восстановлен. Резерв: $DOCKER_BACKUP"
    else
        info "ВНИМАНИЕ: автоматический откат не завершился. Резерв: $DOCKER_BACKUP"
        info "Проверь: docker compose -p $DOCKER_PROJECT -f $DOCKER_COMPOSE_FILE ps $DOCKER_SERVICE"
    fi
}

docker_update() {
    need_root
    DOCKER_NAME=${1:-}
    DOCKER_REQUESTED=${2:-}
    [ -n "$DOCKER_NAME" ] || fail 'Укажи контейнер: --docker-update nginx-selfsteal [nginx:1.30.7-alpine]'
    printf '%s' "$DOCKER_NAME" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]*
    info 'Процессы nginx на хосте (с учётом контейнеров):'
    FOUND=no
    for PID in $(nginx_pids); do
        [ -d "/proc/$PID" ] || continue
        FOUND=yes
        printf '  PID %s: %s\n' "$PID" "$(nginx_process_origin "$PID")"
    done
    [ "$FOUND" = yes ] || info 'Процессы nginx не найдены.'
    info 'Слушающие TCP-порты 80/443:'
    if command -v ss >/dev/null 2>&1; then
        ss -H -lntp 2>/dev/null | awk '$4 ~ /:80$|:443$/ {print}' || true
    else
        info 'ss недоступен.'
    fi
    docker_overview
}

runtime_preflight() {
    MODE=$1
    if has_non_system_nginx || has_docker_nginx; then
        runtime_overview
        fail 'Обнаружен nginx, запущенный вне nginx.service (например, Docker). Не меняю системный пакет: это не обновит работающий контейнер. Используй --docker-status и проверь конфигурацию Compose.'
    fi
    if [ "$MODE" = install ]; then
        command -v ss >/dev/null 2>&1 || fail 'Не найден ss: нельзя безопасно проверить порты 80/443 перед установкой.'
        BUSY=$(ss -H -lntp 2>/dev/null | awk '$4 ~ /:80$|:443$/ {print}' || true)
        [ -z "$BUSY" ] || fail "Порты 80 или 443 уже заняты. Не устанавливаю дополнительный nginx:
$BUSY"
    fi
}

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
    if nginx_installed; then
        info 'Установленный системный nginx:'
        dpkg-query -W -f='Пакет: ${binary:Package} ${Version}\n' nginx
        if command -v nginx >/dev/null 2>&1; then nginx -v 2>&1; fi
    else
        info 'Системный пакет nginx через APT не установлен.'
        if command -v nginx >/dev/null 2>&1; then
            info 'Предупреждение: nginx найден в PATH, но не числится установленным через dpkg.'
            nginx -v 2>&1
        fi
    fi
    if command -v apt-cache >/dev/null 2>&1; then
        apt-cache policy nginx | sed -n '1,12p'
    fi
    if command -v systemctl >/dev/null 2>&1; then
        info "nginx.service: $(systemctl is-active nginx 2>/dev/null || true)"
        info "Автозапуск nginx.service: $(systemctl is-enabled nginx 2>/dev/null || true)"
    fi
    info "Ветка репозитория: $(branch_from_repo)"
    runtime_overview
}

validate() {
    command -v nginx >/dev/null 2>&1 || fail 'nginx не установлен'
    nginx -t
    info 'Активные конфигурационные файлы:'
    nginx -T 2>&1 | grep '^# configuration file ' || true
}

diagnose() {
    runtime_overview
    if nginx_installed; then
        validate
        info 'Настройки HTTP/2 в системном nginx:'
        nginx -T 2>&1 | grep -nE 'listen .*http2|^[[:space:]]*http2[[:space:]]+(on|off)' || true
        info 'Загруженные динамические модули:'
        nginx -T 2>&1 | grep -E '^[[:space:]]*load_module ' || true
    else
        info 'Системный nginx не установлен — проверка его nginx -t не выполняется.'
    fi
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
    ACTION=$2
    check_platform
    if command -v nginx >/dev/null 2>&1 && ! nginx_installed; then
        runtime_overview
        fail 'Найден nginx, не установленный через dpkg. Автоматическая установка/замена запрещена.'
    fi
    if [ "$ACTION" = update ] && ! nginx_installed; then
        runtime_overview
        fail 'Системного nginx нет. --auto не устанавливает второй nginx. Для новой установки без конфликтующих процессов используй --install.'
    fi
    if [ "$ACTION" = install ] && nginx_installed; then
        fail 'Системный nginx уже установлен. Используй --auto, --stable или --mainline.'
    fi
    runtime_preflight "$ACTION"
    if nginx_installed; then
        nginx -t || fail 'Текущая конфигурация содержит ошибки. Сначала исправь nginx -t.'
    fi
    check_modules_before_switch
    if apt-mark showhold | grep -qx nginx; then fail 'nginx находится на hold (apt-mark). Сними блокировку вручную.'; fi
    WAS_ACTIVE=no
    WAS_ENABLED=no
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet nginx; then WAS_ACTIVE=yes; fi
        if systemctl is-enabled --quiet nginx; then WAS_ENABLED=yes; fi
    fi
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
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
        if [ "$ACTION" = install ]; then
            # Установщик пакета может включить службу сам: отменяем это.
            systemctl disable --now nginx || fail 'Не удалось отключить автоматически созданную службу nginx.'
            info 'Новая установка: nginx.service отключён и не будет запускаться после перезагрузки.'
        elif [ "$WAS_ACTIVE" = yes ]; then
            systemctl restart nginx || fail 'nginx не запустился. Проверь journalctl -u nginx -n 100.'
            systemctl is-active --quiet nginx || fail 'nginx неактивен после обновления.'
        fi
        if [ "$ACTION" = update ] && [ "$WAS_ENABLED" = no ]; then
            systemctl disable nginx || fail 'Не удалось сохранить отключённый автозапуск nginx.'
            if [ "$WAS_ACTIVE" = no ] && systemctl is-active --quiet nginx; then
                systemctl stop nginx || fail 'nginx неожиданно запустился во время обновления, не удалось его остановить.'
            fi
        fi
    fi
    info "Успешно: $(nginx -v 2>&1). Резервная копия: $BACKUP_DIR"
    if [ "$WAS_ACTIVE" = no ]; then info "До операции служба была остановлена; текущее состояние: $(systemctl is-active nginx 2>/dev/null || true)"; fi
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
        printf '1) Статус nginx, Docker и портов\n2) Проверить доступные обновления\n3) Обновить установленный nginx stable\n4) Обновить установленный nginx mainline\n5) Проверить nginx -t и подключённые конфиги\n6) Создать резервную копию\n7) Показать резервные копии\n8) Диагностика HTTP/2, портов и модулей\n9) Информация о nginx в Docker\n10) Новая установка системного nginx stable\n11) Обновить Docker-nginx (только выбранный контейнер)\n0) Выход\nВыбор: '
        read -r CHOICE || return 0
        case "$CHOICE" in
            1) status ;;
            2) check_updates ;;
            3) update_nginx stable update ;;
            4) printf 'Для перехода на mainline напиши MAINLINE: '; read -r CONFIRM || return 0; [ "$CONFIRM" = MAINLINE ] && update_nginx mainline update || info 'Отменено' ;;
            5) validate ;;
            6) backup ;;
            7) ls -lht "$BACKUP_ROOT" 2>/dev/null || info 'Резервных копий пока нет' ;;
            8) diagnose ;;
            9) docker_overview ;;
            10) printf 'Для новой установки системного nginx напиши INSTALL: '; read -r CONFIRM || return 0; [ "$CONFIRM" = INSTALL ] && update_nginx stable install || info 'Отменено' ;;
            11) printf 'Имя Docker-контейнера nginx: '; read -r NGINX_CONTAINER || return 0; printf 'Целевой образ (Enter = последняя stable-alpine): '; read -r NGINX_IMAGE || return 0; docker_update "$NGINX_CONTAINER" "$NGINX_IMAGE" ;;
            0) return 0 ;;
            *) info 'Неизвестная команда' ;;
        esac
    done
}

usage() {
    cat <<'EOF'
nginx_updater — управляемое обновление системного nginx через nginx.org.
Запуск: sudo sh nginx-updater.sh [команда]
  --auto          Обновить установленный nginx; ветка nginx.org сохраняется (по умолчанию)
  --stable        Обновить установленный nginx stable
  --mainline      Обновить установленный nginx mainline
  --install       Установить системный nginx stable с нуля (не запускать, не включать)
  --menu          Интерактивное меню
  --status        Показать APT, Docker, процессы и порты
  --docker-status Обнаружить контейнеры с nginx и показать их версии/Compose
  --docker-update NAME [IMAGE] Обновить выбранный Docker Compose nginx до актуальной stable-alpine
                            (или IMAGE: nginx:X.Y.Z-alpine)
  --check         Обновить индексы APT и показать доступные версии
  --test          nginx -t для системного nginx и список конфигураций
  --diagnose      Проверка HTTP/2, модулей и прослушиваемых портов
  --backup        Создать резервную копию /etc/nginx
  --help          Показать справку

Безопасность: --auto больше НЕ устанавливает nginx, если его нет в APT.
При обнаружении nginx в Docker или других внешних процессах изменение системного пакета
блокируется. Docker обновляется только явно: --docker-update NAME [IMAGE].
Поддержка: Ubuntu 22.04/24.04/26.04, Debian 12/13; amd64/arm64.
EOF
}

case "${1:---auto}" in
    --auto) update_nginx "$(branch_from_repo)" update ;;
    --stable) update_nginx stable update ;;
    --mainline) update_nginx mainline update ;;
    --install) update_nginx stable install ;;
    --menu) menu ;;
    --status) status ;;
    --docker-status) docker_overview ;;
    --docker-update) docker_update "${2:-}" "${3:-}" ;;
    --check) check_updates ;;
    --test) validate ;;
    --diagnose) diagnose ;;
    --backup) backup ;;
    --help|-h) usage ;;
    *) usage; exit 2 ;;
esac
 || fail 'Недопустимое имя контейнера.'
    command -v docker >/dev/null 2>&1 || fail 'Docker не установлен.'
    docker info >/dev/null 2>&1 || fail 'Docker daemon недоступен.'
    docker compose version >/dev/null 2>&1 || fail 'Требуется Docker Compose v2.'
    command -v python3 >/dev/null 2>&1 || fail 'Для проверки Compose требуется python3.'
    command -v dpkg >/dev/null 2>&1 || fail 'Для сравнения версий требуется dpkg.'
    [ "$(docker inspect -f '${.State.Running}' "$DOCKER_NAME" 2>/dev/null)" = true ] ||
        fail "Контейнер $DOCKER_NAME отсутствует или остановлен."

    DOCKER_WORKDIR=$(docker inspect -f '${index .Config.Labels "com.docker.compose.project.working_dir"}' "$DOCKER_NAME")
    DOCKER_COMPOSE_FILE=$(docker inspect -f '${index .Config.Labels "com.docker.compose.project.config_files"}' "$DOCKER_NAME")
    DOCKER_PROJECT=$(docker inspect -f '${index .Config.Labels "com.docker.compose.project"}' "$DOCKER_NAME")
    DOCKER_SERVICE=$(docker inspect -f '${index .Config.Labels "com.docker.compose.service"}' "$DOCKER_NAME")
    case "$DOCKER_WORKDIR" in /*) ;; *) fail 'Не найден абсолютный путь к Compose-проекту.' ;; esac
    case "$DOCKER_COMPOSE_FILE" in
        /*) ;;
        *) fail 'Compose-файл не найден. Поддерживается только Compose с одним абсолютным файлом.' ;;
    esac
    case "$DOCKER_COMPOSE_FILE" in *,*) fail 'Для безопасности несколько Compose-файлов пока не поддерживаются.' ;; esac
    [ -f "$DOCKER_COMPOSE_FILE" ] && [ ! -L "$DOCKER_COMPOSE_FILE" ] ||
        fail 'Compose-файл отсутствует или является символической ссылкой.'
    [ -d "$DOCKER_WORKDIR" ] || fail 'Не найдена рабочая директория проекта.'
    printf '%s' "$DOCKER_PROJECT" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]*
    info 'Процессы nginx на хосте (с учётом контейнеров):'
    FOUND=no
    for PID in $(nginx_pids); do
        [ -d "/proc/$PID" ] || continue
        FOUND=yes
        printf '  PID %s: %s\n' "$PID" "$(nginx_process_origin "$PID")"
    done
    [ "$FOUND" = yes ] || info 'Процессы nginx не найдены.'
    info 'Слушающие TCP-порты 80/443:'
    if command -v ss >/dev/null 2>&1; then
        ss -H -lntp 2>/dev/null | awk '$4 ~ /:80$|:443$/ {print}' || true
    else
        info 'ss недоступен.'
    fi
    docker_overview
}

runtime_preflight() {
    MODE=$1
    if has_non_system_nginx || has_docker_nginx; then
        runtime_overview
        fail 'Обнаружен nginx, запущенный вне nginx.service (например, Docker). Не меняю системный пакет: это не обновит работающий контейнер. Используй --docker-status и проверь конфигурацию Compose.'
    fi
    if [ "$MODE" = install ]; then
        command -v ss >/dev/null 2>&1 || fail 'Не найден ss: нельзя безопасно проверить порты 80/443 перед установкой.'
        BUSY=$(ss -H -lntp 2>/dev/null | awk '$4 ~ /:80$|:443$/ {print}' || true)
        [ -z "$BUSY" ] || fail "Порты 80 или 443 уже заняты. Не устанавливаю дополнительный nginx:
$BUSY"
    fi
}

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
    if nginx_installed; then
        info 'Установленный системный nginx:'
        dpkg-query -W -f='Пакет: ${binary:Package} ${Version}\n' nginx
        if command -v nginx >/dev/null 2>&1; then nginx -v 2>&1; fi
    else
        info 'Системный пакет nginx через APT не установлен.'
        if command -v nginx >/dev/null 2>&1; then
            info 'Предупреждение: nginx найден в PATH, но не числится установленным через dpkg.'
            nginx -v 2>&1
        fi
    fi
    if command -v apt-cache >/dev/null 2>&1; then
        apt-cache policy nginx | sed -n '1,12p'
    fi
    if command -v systemctl >/dev/null 2>&1; then
        info "nginx.service: $(systemctl is-active nginx 2>/dev/null || true)"
        info "Автозапуск nginx.service: $(systemctl is-enabled nginx 2>/dev/null || true)"
    fi
    info "Ветка репозитория: $(branch_from_repo)"
    runtime_overview
}

validate() {
    command -v nginx >/dev/null 2>&1 || fail 'nginx не установлен'
    nginx -t
    info 'Активные конфигурационные файлы:'
    nginx -T 2>&1 | grep '^# configuration file ' || true
}

diagnose() {
    runtime_overview
    if nginx_installed; then
        validate
        info 'Настройки HTTP/2 в системном nginx:'
        nginx -T 2>&1 | grep -nE 'listen .*http2|^[[:space:]]*http2[[:space:]]+(on|off)' || true
        info 'Загруженные динамические модули:'
        nginx -T 2>&1 | grep -E '^[[:space:]]*load_module ' || true
    else
        info 'Системный nginx не установлен — проверка его nginx -t не выполняется.'
    fi
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
    ACTION=$2
    check_platform
    if command -v nginx >/dev/null 2>&1 && ! nginx_installed; then
        runtime_overview
        fail 'Найден nginx, не установленный через dpkg. Автоматическая установка/замена запрещена.'
    fi
    if [ "$ACTION" = update ] && ! nginx_installed; then
        runtime_overview
        fail 'Системного nginx нет. --auto не устанавливает второй nginx. Для новой установки без конфликтующих процессов используй --install.'
    fi
    if [ "$ACTION" = install ] && nginx_installed; then
        fail 'Системный nginx уже установлен. Используй --auto, --stable или --mainline.'
    fi
    runtime_preflight "$ACTION"
    if nginx_installed; then
        nginx -t || fail 'Текущая конфигурация содержит ошибки. Сначала исправь nginx -t.'
    fi
    check_modules_before_switch
    if apt-mark showhold | grep -qx nginx; then fail 'nginx находится на hold (apt-mark). Сними блокировку вручную.'; fi
    WAS_ACTIVE=no
    WAS_ENABLED=no
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet nginx; then WAS_ACTIVE=yes; fi
        if systemctl is-enabled --quiet nginx; then WAS_ENABLED=yes; fi
    fi
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
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
        if [ "$ACTION" = install ]; then
            # Установщик пакета может включить службу сам: отменяем это.
            systemctl disable --now nginx || fail 'Не удалось отключить автоматически созданную службу nginx.'
            info 'Новая установка: nginx.service отключён и не будет запускаться после перезагрузки.'
        elif [ "$WAS_ACTIVE" = yes ]; then
            systemctl restart nginx || fail 'nginx не запустился. Проверь journalctl -u nginx -n 100.'
            systemctl is-active --quiet nginx || fail 'nginx неактивен после обновления.'
        fi
        if [ "$ACTION" = update ] && [ "$WAS_ENABLED" = no ]; then
            systemctl disable nginx || fail 'Не удалось сохранить отключённый автозапуск nginx.'
            if [ "$WAS_ACTIVE" = no ] && systemctl is-active --quiet nginx; then
                systemctl stop nginx || fail 'nginx неожиданно запустился во время обновления, не удалось его остановить.'
            fi
        fi
    fi
    info "Успешно: $(nginx -v 2>&1). Резервная копия: $BACKUP_DIR"
    if [ "$WAS_ACTIVE" = no ]; then info "До операции служба была остановлена; текущее состояние: $(systemctl is-active nginx 2>/dev/null || true)"; fi
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
        printf '1) Статус nginx, Docker и портов\n2) Проверить доступные обновления\n3) Обновить установленный nginx stable\n4) Обновить установленный nginx mainline\n5) Проверить nginx -t и подключённые конфиги\n6) Создать резервную копию\n7) Показать резервные копии\n8) Диагностика HTTP/2, портов и модулей\n9) Информация о nginx в Docker\n10) Новая установка системного nginx stable\n0) Выход\nВыбор: '
        read -r CHOICE || return 0
        case "$CHOICE" in
            1) status ;;
            2) check_updates ;;
            3) update_nginx stable update ;;
            4) printf 'Для перехода на mainline напиши MAINLINE: '; read -r CONFIRM || return 0; [ "$CONFIRM" = MAINLINE ] && update_nginx mainline update || info 'Отменено' ;;
            5) validate ;;
            6) backup ;;
            7) ls -lht "$BACKUP_ROOT" 2>/dev/null || info 'Резервных копий пока нет' ;;
            8) diagnose ;;
            9) docker_overview ;;
            10) printf 'Для новой установки системного nginx напиши INSTALL: '; read -r CONFIRM || return 0; [ "$CONFIRM" = INSTALL ] && update_nginx stable install || info 'Отменено' ;;
            0) return 0 ;;
            *) info 'Неизвестная команда' ;;
        esac
    done
}

usage() {
    cat <<'EOF'
nginx_updater — управляемое обновление системного nginx через nginx.org.
Запуск: sudo sh nginx-updater.sh [команда]
  --auto          Обновить установленный nginx; ветка nginx.org сохраняется (по умолчанию)
  --stable        Обновить установленный nginx stable
  --mainline      Обновить установленный nginx mainline
  --install       Установить системный nginx stable с нуля (не запускать, не включать)
  --menu          Интерактивное меню
  --status        Показать APT, Docker, процессы и порты
  --docker-status Обнаружить контейнеры с nginx и показать их версии/Compose
  --check         Обновить индексы APT и показать доступные версии
  --test          nginx -t для системного nginx и список конфигураций
  --diagnose      Проверка HTTP/2, модулей и прослушиваемых портов
  --backup        Создать резервную копию /etc/nginx
  --help          Показать справку

Безопасность: --auto больше НЕ устанавливает nginx, если его нет в APT.
При обнаружении nginx в Docker или других внешних процессах изменение системного пакета
блокируется. Контейнеры автоматически НЕ обновляются: нужно обновить тег образа/Compose.
Поддержка: Ubuntu 22.04/24.04/26.04, Debian 12/13; amd64/arm64.
EOF
}

case "${1:---auto}" in
    --auto) update_nginx "$(branch_from_repo)" update ;;
    --stable) update_nginx stable update ;;
    --mainline) update_nginx mainline update ;;
    --install) update_nginx stable install ;;
    --menu) menu ;;
    --status) status ;;
    --docker-status) docker_overview ;;
    --check) check_updates ;;
    --test) validate ;;
    --diagnose) diagnose ;;
    --backup) backup ;;
    --help|-h) usage ;;
    *) usage; exit 2 ;;
esac
 || fail 'Некорректная метка проекта.'
    printf '%s' "$DOCKER_SERVICE" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]*
    info 'Процессы nginx на хосте (с учётом контейнеров):'
    FOUND=no
    for PID in $(nginx_pids); do
        [ -d "/proc/$PID" ] || continue
        FOUND=yes
        printf '  PID %s: %s\n' "$PID" "$(nginx_process_origin "$PID")"
    done
    [ "$FOUND" = yes ] || info 'Процессы nginx не найдены.'
    info 'Слушающие TCP-порты 80/443:'
    if command -v ss >/dev/null 2>&1; then
        ss -H -lntp 2>/dev/null | awk '$4 ~ /:80$|:443$/ {print}' || true
    else
        info 'ss недоступен.'
    fi
    docker_overview
}

runtime_preflight() {
    MODE=$1
    if has_non_system_nginx || has_docker_nginx; then
        runtime_overview
        fail 'Обнаружен nginx, запущенный вне nginx.service (например, Docker). Не меняю системный пакет: это не обновит работающий контейнер. Используй --docker-status и проверь конфигурацию Compose.'
    fi
    if [ "$MODE" = install ]; then
        command -v ss >/dev/null 2>&1 || fail 'Не найден ss: нельзя безопасно проверить порты 80/443 перед установкой.'
        BUSY=$(ss -H -lntp 2>/dev/null | awk '$4 ~ /:80$|:443$/ {print}' || true)
        [ -z "$BUSY" ] || fail "Порты 80 или 443 уже заняты. Не устанавливаю дополнительный nginx:
$BUSY"
    fi
}

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
    if nginx_installed; then
        info 'Установленный системный nginx:'
        dpkg-query -W -f='Пакет: ${binary:Package} ${Version}\n' nginx
        if command -v nginx >/dev/null 2>&1; then nginx -v 2>&1; fi
    else
        info 'Системный пакет nginx через APT не установлен.'
        if command -v nginx >/dev/null 2>&1; then
            info 'Предупреждение: nginx найден в PATH, но не числится установленным через dpkg.'
            nginx -v 2>&1
        fi
    fi
    if command -v apt-cache >/dev/null 2>&1; then
        apt-cache policy nginx | sed -n '1,12p'
    fi
    if command -v systemctl >/dev/null 2>&1; then
        info "nginx.service: $(systemctl is-active nginx 2>/dev/null || true)"
        info "Автозапуск nginx.service: $(systemctl is-enabled nginx 2>/dev/null || true)"
    fi
    info "Ветка репозитория: $(branch_from_repo)"
    runtime_overview
}

validate() {
    command -v nginx >/dev/null 2>&1 || fail 'nginx не установлен'
    nginx -t
    info 'Активные конфигурационные файлы:'
    nginx -T 2>&1 | grep '^# configuration file ' || true
}

diagnose() {
    runtime_overview
    if nginx_installed; then
        validate
        info 'Настройки HTTP/2 в системном nginx:'
        nginx -T 2>&1 | grep -nE 'listen .*http2|^[[:space:]]*http2[[:space:]]+(on|off)' || true
        info 'Загруженные динамические модули:'
        nginx -T 2>&1 | grep -E '^[[:space:]]*load_module ' || true
    else
        info 'Системный nginx не установлен — проверка его nginx -t не выполняется.'
    fi
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
    ACTION=$2
    check_platform
    if command -v nginx >/dev/null 2>&1 && ! nginx_installed; then
        runtime_overview
        fail 'Найден nginx, не установленный через dpkg. Автоматическая установка/замена запрещена.'
    fi
    if [ "$ACTION" = update ] && ! nginx_installed; then
        runtime_overview
        fail 'Системного nginx нет. --auto не устанавливает второй nginx. Для новой установки без конфликтующих процессов используй --install.'
    fi
    if [ "$ACTION" = install ] && nginx_installed; then
        fail 'Системный nginx уже установлен. Используй --auto, --stable или --mainline.'
    fi
    runtime_preflight "$ACTION"
    if nginx_installed; then
        nginx -t || fail 'Текущая конфигурация содержит ошибки. Сначала исправь nginx -t.'
    fi
    check_modules_before_switch
    if apt-mark showhold | grep -qx nginx; then fail 'nginx находится на hold (apt-mark). Сними блокировку вручную.'; fi
    WAS_ACTIVE=no
    WAS_ENABLED=no
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet nginx; then WAS_ACTIVE=yes; fi
        if systemctl is-enabled --quiet nginx; then WAS_ENABLED=yes; fi
    fi
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
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
        if [ "$ACTION" = install ]; then
            # Установщик пакета может включить службу сам: отменяем это.
            systemctl disable --now nginx || fail 'Не удалось отключить автоматически созданную службу nginx.'
            info 'Новая установка: nginx.service отключён и не будет запускаться после перезагрузки.'
        elif [ "$WAS_ACTIVE" = yes ]; then
            systemctl restart nginx || fail 'nginx не запустился. Проверь journalctl -u nginx -n 100.'
            systemctl is-active --quiet nginx || fail 'nginx неактивен после обновления.'
        fi
        if [ "$ACTION" = update ] && [ "$WAS_ENABLED" = no ]; then
            systemctl disable nginx || fail 'Не удалось сохранить отключённый автозапуск nginx.'
            if [ "$WAS_ACTIVE" = no ] && systemctl is-active --quiet nginx; then
                systemctl stop nginx || fail 'nginx неожиданно запустился во время обновления, не удалось его остановить.'
            fi
        fi
    fi
    info "Успешно: $(nginx -v 2>&1). Резервная копия: $BACKUP_DIR"
    if [ "$WAS_ACTIVE" = no ]; then info "До операции служба была остановлена; текущее состояние: $(systemctl is-active nginx 2>/dev/null || true)"; fi
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
        printf '1) Статус nginx, Docker и портов\n2) Проверить доступные обновления\n3) Обновить установленный nginx stable\n4) Обновить установленный nginx mainline\n5) Проверить nginx -t и подключённые конфиги\n6) Создать резервную копию\n7) Показать резервные копии\n8) Диагностика HTTP/2, портов и модулей\n9) Информация о nginx в Docker\n10) Новая установка системного nginx stable\n0) Выход\nВыбор: '
        read -r CHOICE || return 0
        case "$CHOICE" in
            1) status ;;
            2) check_updates ;;
            3) update_nginx stable update ;;
            4) printf 'Для перехода на mainline напиши MAINLINE: '; read -r CONFIRM || return 0; [ "$CONFIRM" = MAINLINE ] && update_nginx mainline update || info 'Отменено' ;;
            5) validate ;;
            6) backup ;;
            7) ls -lht "$BACKUP_ROOT" 2>/dev/null || info 'Резервных копий пока нет' ;;
            8) diagnose ;;
            9) docker_overview ;;
            10) printf 'Для новой установки системного nginx напиши INSTALL: '; read -r CONFIRM || return 0; [ "$CONFIRM" = INSTALL ] && update_nginx stable install || info 'Отменено' ;;
            0) return 0 ;;
            *) info 'Неизвестная команда' ;;
        esac
    done
}

usage() {
    cat <<'EOF'
nginx_updater — управляемое обновление системного nginx через nginx.org.
Запуск: sudo sh nginx-updater.sh [команда]
  --auto          Обновить установленный nginx; ветка nginx.org сохраняется (по умолчанию)
  --stable        Обновить установленный nginx stable
  --mainline      Обновить установленный nginx mainline
  --install       Установить системный nginx stable с нуля (не запускать, не включать)
  --menu          Интерактивное меню
  --status        Показать APT, Docker, процессы и порты
  --docker-status Обнаружить контейнеры с nginx и показать их версии/Compose
  --check         Обновить индексы APT и показать доступные версии
  --test          nginx -t для системного nginx и список конфигураций
  --diagnose      Проверка HTTP/2, модулей и прослушиваемых портов
  --backup        Создать резервную копию /etc/nginx
  --help          Показать справку

Безопасность: --auto больше НЕ устанавливает nginx, если его нет в APT.
При обнаружении nginx в Docker или других внешних процессах изменение системного пакета
блокируется. Контейнеры автоматически НЕ обновляются: нужно обновить тег образа/Compose.
Поддержка: Ubuntu 22.04/24.04/26.04, Debian 12/13; amd64/arm64.
EOF
}

case "${1:---auto}" in
    --auto) update_nginx "$(branch_from_repo)" update ;;
    --stable) update_nginx stable update ;;
    --mainline) update_nginx mainline update ;;
    --install) update_nginx stable install ;;
    --menu) menu ;;
    --status) status ;;
    --docker-status) docker_overview ;;
    --check) check_updates ;;
    --test) validate ;;
    --diagnose) diagnose ;;
    --backup) backup ;;
    --help|-h) usage ;;
    *) usage; exit 2 ;;
esac
 || fail 'Некорректная метка сервиса.'
    DOCKER_OLD_IMAGE=$(docker inspect -f '${.Config.Image}' "$DOCKER_NAME")
    printf '%s' "$DOCKER_OLD_IMAGE" | grep -Eq '^nginx:[0-9]+\.[0-9]+\.[0-9]+-alpine
    info 'Процессы nginx на хосте (с учётом контейнеров):'
    FOUND=no
    for PID in $(nginx_pids); do
        [ -d "/proc/$PID" ] || continue
        FOUND=yes
        printf '  PID %s: %s\n' "$PID" "$(nginx_process_origin "$PID")"
    done
    [ "$FOUND" = yes ] || info 'Процессы nginx не найдены.'
    info 'Слушающие TCP-порты 80/443:'
    if command -v ss >/dev/null 2>&1; then
        ss -H -lntp 2>/dev/null | awk '$4 ~ /:80$|:443$/ {print}' || true
    else
        info 'ss недоступен.'
    fi
    docker_overview
}

runtime_preflight() {
    MODE=$1
    if has_non_system_nginx || has_docker_nginx; then
        runtime_overview
        fail 'Обнаружен nginx, запущенный вне nginx.service (например, Docker). Не меняю системный пакет: это не обновит работающий контейнер. Используй --docker-status и проверь конфигурацию Compose.'
    fi
    if [ "$MODE" = install ]; then
        command -v ss >/dev/null 2>&1 || fail 'Не найден ss: нельзя безопасно проверить порты 80/443 перед установкой.'
        BUSY=$(ss -H -lntp 2>/dev/null | awk '$4 ~ /:80$|:443$/ {print}' || true)
        [ -z "$BUSY" ] || fail "Порты 80 или 443 уже заняты. Не устанавливаю дополнительный nginx:
$BUSY"
    fi
}

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
    if nginx_installed; then
        info 'Установленный системный nginx:'
        dpkg-query -W -f='Пакет: ${binary:Package} ${Version}\n' nginx
        if command -v nginx >/dev/null 2>&1; then nginx -v 2>&1; fi
    else
        info 'Системный пакет nginx через APT не установлен.'
        if command -v nginx >/dev/null 2>&1; then
            info 'Предупреждение: nginx найден в PATH, но не числится установленным через dpkg.'
            nginx -v 2>&1
        fi
    fi
    if command -v apt-cache >/dev/null 2>&1; then
        apt-cache policy nginx | sed -n '1,12p'
    fi
    if command -v systemctl >/dev/null 2>&1; then
        info "nginx.service: $(systemctl is-active nginx 2>/dev/null || true)"
        info "Автозапуск nginx.service: $(systemctl is-enabled nginx 2>/dev/null || true)"
    fi
    info "Ветка репозитория: $(branch_from_repo)"
    runtime_overview
}

validate() {
    command -v nginx >/dev/null 2>&1 || fail 'nginx не установлен'
    nginx -t
    info 'Активные конфигурационные файлы:'
    nginx -T 2>&1 | grep '^# configuration file ' || true
}

diagnose() {
    runtime_overview
    if nginx_installed; then
        validate
        info 'Настройки HTTP/2 в системном nginx:'
        nginx -T 2>&1 | grep -nE 'listen .*http2|^[[:space:]]*http2[[:space:]]+(on|off)' || true
        info 'Загруженные динамические модули:'
        nginx -T 2>&1 | grep -E '^[[:space:]]*load_module ' || true
    else
        info 'Системный nginx не установлен — проверка его nginx -t не выполняется.'
    fi
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
    ACTION=$2
    check_platform
    if command -v nginx >/dev/null 2>&1 && ! nginx_installed; then
        runtime_overview
        fail 'Найден nginx, не установленный через dpkg. Автоматическая установка/замена запрещена.'
    fi
    if [ "$ACTION" = update ] && ! nginx_installed; then
        runtime_overview
        fail 'Системного nginx нет. --auto не устанавливает второй nginx. Для новой установки без конфликтующих процессов используй --install.'
    fi
    if [ "$ACTION" = install ] && nginx_installed; then
        fail 'Системный nginx уже установлен. Используй --auto, --stable или --mainline.'
    fi
    runtime_preflight "$ACTION"
    if nginx_installed; then
        nginx -t || fail 'Текущая конфигурация содержит ошибки. Сначала исправь nginx -t.'
    fi
    check_modules_before_switch
    if apt-mark showhold | grep -qx nginx; then fail 'nginx находится на hold (apt-mark). Сними блокировку вручную.'; fi
    WAS_ACTIVE=no
    WAS_ENABLED=no
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet nginx; then WAS_ACTIVE=yes; fi
        if systemctl is-enabled --quiet nginx; then WAS_ENABLED=yes; fi
    fi
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
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
        if [ "$ACTION" = install ]; then
            # Установщик пакета может включить службу сам: отменяем это.
            systemctl disable --now nginx || fail 'Не удалось отключить автоматически созданную службу nginx.'
            info 'Новая установка: nginx.service отключён и не будет запускаться после перезагрузки.'
        elif [ "$WAS_ACTIVE" = yes ]; then
            systemctl restart nginx || fail 'nginx не запустился. Проверь journalctl -u nginx -n 100.'
            systemctl is-active --quiet nginx || fail 'nginx неактивен после обновления.'
        fi
        if [ "$ACTION" = update ] && [ "$WAS_ENABLED" = no ]; then
            systemctl disable nginx || fail 'Не удалось сохранить отключённый автозапуск nginx.'
            if [ "$WAS_ACTIVE" = no ] && systemctl is-active --quiet nginx; then
                systemctl stop nginx || fail 'nginx неожиданно запустился во время обновления, не удалось его остановить.'
            fi
        fi
    fi
    info "Успешно: $(nginx -v 2>&1). Резервная копия: $BACKUP_DIR"
    if [ "$WAS_ACTIVE" = no ]; then info "До операции служба была остановлена; текущее состояние: $(systemctl is-active nginx 2>/dev/null || true)"; fi
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
        printf '1) Статус nginx, Docker и портов\n2) Проверить доступные обновления\n3) Обновить установленный nginx stable\n4) Обновить установленный nginx mainline\n5) Проверить nginx -t и подключённые конфиги\n6) Создать резервную копию\n7) Показать резервные копии\n8) Диагностика HTTP/2, портов и модулей\n9) Информация о nginx в Docker\n10) Новая установка системного nginx stable\n0) Выход\nВыбор: '
        read -r CHOICE || return 0
        case "$CHOICE" in
            1) status ;;
            2) check_updates ;;
            3) update_nginx stable update ;;
            4) printf 'Для перехода на mainline напиши MAINLINE: '; read -r CONFIRM || return 0; [ "$CONFIRM" = MAINLINE ] && update_nginx mainline update || info 'Отменено' ;;
            5) validate ;;
            6) backup ;;
            7) ls -lht "$BACKUP_ROOT" 2>/dev/null || info 'Резервных копий пока нет' ;;
            8) diagnose ;;
            9) docker_overview ;;
            10) printf 'Для новой установки системного nginx напиши INSTALL: '; read -r CONFIRM || return 0; [ "$CONFIRM" = INSTALL ] && update_nginx stable install || info 'Отменено' ;;
            0) return 0 ;;
            *) info 'Неизвестная команда' ;;
        esac
    done
}

usage() {
    cat <<'EOF'
nginx_updater — управляемое обновление системного nginx через nginx.org.
Запуск: sudo sh nginx-updater.sh [команда]
  --auto          Обновить установленный nginx; ветка nginx.org сохраняется (по умолчанию)
  --stable        Обновить установленный nginx stable
  --mainline      Обновить установленный nginx mainline
  --install       Установить системный nginx stable с нуля (не запускать, не включать)
  --menu          Интерактивное меню
  --status        Показать APT, Docker, процессы и порты
  --docker-status Обнаружить контейнеры с nginx и показать их версии/Compose
  --check         Обновить индексы APT и показать доступные версии
  --test          nginx -t для системного nginx и список конфигураций
  --diagnose      Проверка HTTP/2, модулей и прослушиваемых портов
  --backup        Создать резервную копию /etc/nginx
  --help          Показать справку

Безопасность: --auto больше НЕ устанавливает nginx, если его нет в APT.
При обнаружении nginx в Docker или других внешних процессах изменение системного пакета
блокируется. Контейнеры автоматически НЕ обновляются: нужно обновить тег образа/Compose.
Поддержка: Ubuntu 22.04/24.04/26.04, Debian 12/13; amd64/arm64.
EOF
}

case "${1:---auto}" in
    --auto) update_nginx "$(branch_from_repo)" update ;;
    --stable) update_nginx stable update ;;
    --mainline) update_nginx mainline update ;;
    --install) update_nginx stable install ;;
    --menu) menu ;;
    --status) status ;;
    --docker-status) docker_overview ;;
    --check) check_updates ;;
    --test) validate ;;
    --diagnose) diagnose ;;
    --backup) backup ;;
    --help|-h) usage ;;
    *) usage; exit 2 ;;
esac
 ||
        fail "Образ $DOCKER_OLD_IMAGE не является ожидаемым официальным nginx:X.Y.Z-alpine. Автоматически не меняю кастомный образ."
    DOCKER_OLD_VERSION=${DOCKER_OLD_IMAGE#nginx:}
    DOCKER_OLD_VERSION=${DOCKER_OLD_VERSION%-alpine}

    info "Контейнер: $DOCKER_NAME; проект: $DOCKER_PROJECT; сервис: $DOCKER_SERVICE"
    info "Compose: $DOCKER_COMPOSE_FILE; текущий образ: $DOCKER_OLD_IMAGE"
    docker compose -p "$DOCKER_PROJECT" --project-directory "$DOCKER_WORKDIR" -f "$DOCKER_COMPOSE_FILE" config -q ||
        fail 'Исходная конфигурация Compose содержит ошибки.'
    docker compose -p "$DOCKER_PROJECT" --project-directory "$DOCKER_WORKDIR" -f "$DOCKER_COMPOSE_FILE" config --format json |
        python3 -c 'import json,sys; p=json.load(sys.stdin); s=p.get("services",{}).get(sys.argv[1],{}); sys.exit(0 if s.get("image")==sys.argv[2] else 1)' "$DOCKER_SERVICE" "$DOCKER_OLD_IMAGE" ||
        fail 'Образ из Compose не совпадает с образом контейнера: автоматическая правка опасна.'
    docker exec "$DOCKER_NAME" nginx -t || fail 'Действующий контейнер имеет ошибку nginx -t. Обновление остановлено.'

    DOCKER_MATCHES=$(awk -v old="$DOCKER_OLD_IMAGE" '{
        line=$0; sub(/^[ \t]*/, "", line);
        if (line=="image: " old) n++;
    } END {print n+0}' "$DOCKER_COMPOSE_FILE")
    [ "$DOCKER_MATCHES" = 1 ] ||
        fail "Нужна ровно одна строка 'image: $DOCKER_OLD_IMAGE' в Compose. Найдено: $DOCKER_MATCHES. Не изменяю сложный YAML автоматически."

    if [ -z "$DOCKER_REQUESTED" ]; then
        info 'Получаю актуальный официальный nginx:stable-alpine и фиксирую точный номер версии.'
        docker pull nginx:stable-alpine || fail 'Не удалось скачать nginx:stable-alpine.'
        DOCKER_VERSION_OUTPUT=$(docker run --rm --entrypoint nginx nginx:stable-alpine -v 2>&1) ||
            fail 'Не удалось проверить версию nginx:stable-alpine.'
        DOCKER_VERSION=$(printf '%s\n' "$DOCKER_VERSION_OUTPUT" |
            sed -n 's/^nginx version: nginx\/\([0-9][0-9.]*\)$/\1/p' | head -n 1)
        [ -n "$DOCKER_VERSION" ] || fail "Не удалось определить стабильную версию: $DOCKER_VERSION_OUTPUT"
        DOCKER_TARGET="nginx:$DOCKER_VERSION-alpine"
    else
        DOCKER_TARGET=$DOCKER_REQUESTED
        printf '%s' "$DOCKER_TARGET" | grep -Eq '^nginx:[0-9]+\.[0-9]+\.[0-9]+-alpine
    info 'Процессы nginx на хосте (с учётом контейнеров):'
    FOUND=no
    for PID in $(nginx_pids); do
        [ -d "/proc/$PID" ] || continue
        FOUND=yes
        printf '  PID %s: %s\n' "$PID" "$(nginx_process_origin "$PID")"
    done
    [ "$FOUND" = yes ] || info 'Процессы nginx не найдены.'
    info 'Слушающие TCP-порты 80/443:'
    if command -v ss >/dev/null 2>&1; then
        ss -H -lntp 2>/dev/null | awk '$4 ~ /:80$|:443$/ {print}' || true
    else
        info 'ss недоступен.'
    fi
    docker_overview
}

runtime_preflight() {
    MODE=$1
    if has_non_system_nginx || has_docker_nginx; then
        runtime_overview
        fail 'Обнаружен nginx, запущенный вне nginx.service (например, Docker). Не меняю системный пакет: это не обновит работающий контейнер. Используй --docker-status и проверь конфигурацию Compose.'
    fi
    if [ "$MODE" = install ]; then
        command -v ss >/dev/null 2>&1 || fail 'Не найден ss: нельзя безопасно проверить порты 80/443 перед установкой.'
        BUSY=$(ss -H -lntp 2>/dev/null | awk '$4 ~ /:80$|:443$/ {print}' || true)
        [ -z "$BUSY" ] || fail "Порты 80 или 443 уже заняты. Не устанавливаю дополнительный nginx:
$BUSY"
    fi
}

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
    if nginx_installed; then
        info 'Установленный системный nginx:'
        dpkg-query -W -f='Пакет: ${binary:Package} ${Version}\n' nginx
        if command -v nginx >/dev/null 2>&1; then nginx -v 2>&1; fi
    else
        info 'Системный пакет nginx через APT не установлен.'
        if command -v nginx >/dev/null 2>&1; then
            info 'Предупреждение: nginx найден в PATH, но не числится установленным через dpkg.'
            nginx -v 2>&1
        fi
    fi
    if command -v apt-cache >/dev/null 2>&1; then
        apt-cache policy nginx | sed -n '1,12p'
    fi
    if command -v systemctl >/dev/null 2>&1; then
        info "nginx.service: $(systemctl is-active nginx 2>/dev/null || true)"
        info "Автозапуск nginx.service: $(systemctl is-enabled nginx 2>/dev/null || true)"
    fi
    info "Ветка репозитория: $(branch_from_repo)"
    runtime_overview
}

validate() {
    command -v nginx >/dev/null 2>&1 || fail 'nginx не установлен'
    nginx -t
    info 'Активные конфигурационные файлы:'
    nginx -T 2>&1 | grep '^# configuration file ' || true
}

diagnose() {
    runtime_overview
    if nginx_installed; then
        validate
        info 'Настройки HTTP/2 в системном nginx:'
        nginx -T 2>&1 | grep -nE 'listen .*http2|^[[:space:]]*http2[[:space:]]+(on|off)' || true
        info 'Загруженные динамические модули:'
        nginx -T 2>&1 | grep -E '^[[:space:]]*load_module ' || true
    else
        info 'Системный nginx не установлен — проверка его nginx -t не выполняется.'
    fi
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
    ACTION=$2
    check_platform
    if command -v nginx >/dev/null 2>&1 && ! nginx_installed; then
        runtime_overview
        fail 'Найден nginx, не установленный через dpkg. Автоматическая установка/замена запрещена.'
    fi
    if [ "$ACTION" = update ] && ! nginx_installed; then
        runtime_overview
        fail 'Системного nginx нет. --auto не устанавливает второй nginx. Для новой установки без конфликтующих процессов используй --install.'
    fi
    if [ "$ACTION" = install ] && nginx_installed; then
        fail 'Системный nginx уже установлен. Используй --auto, --stable или --mainline.'
    fi
    runtime_preflight "$ACTION"
    if nginx_installed; then
        nginx -t || fail 'Текущая конфигурация содержит ошибки. Сначала исправь nginx -t.'
    fi
    check_modules_before_switch
    if apt-mark showhold | grep -qx nginx; then fail 'nginx находится на hold (apt-mark). Сними блокировку вручную.'; fi
    WAS_ACTIVE=no
    WAS_ENABLED=no
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet nginx; then WAS_ACTIVE=yes; fi
        if systemctl is-enabled --quiet nginx; then WAS_ENABLED=yes; fi
    fi
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
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
        if [ "$ACTION" = install ]; then
            # Установщик пакета может включить службу сам: отменяем это.
            systemctl disable --now nginx || fail 'Не удалось отключить автоматически созданную службу nginx.'
            info 'Новая установка: nginx.service отключён и не будет запускаться после перезагрузки.'
        elif [ "$WAS_ACTIVE" = yes ]; then
            systemctl restart nginx || fail 'nginx не запустился. Проверь journalctl -u nginx -n 100.'
            systemctl is-active --quiet nginx || fail 'nginx неактивен после обновления.'
        fi
        if [ "$ACTION" = update ] && [ "$WAS_ENABLED" = no ]; then
            systemctl disable nginx || fail 'Не удалось сохранить отключённый автозапуск nginx.'
            if [ "$WAS_ACTIVE" = no ] && systemctl is-active --quiet nginx; then
                systemctl stop nginx || fail 'nginx неожиданно запустился во время обновления, не удалось его остановить.'
            fi
        fi
    fi
    info "Успешно: $(nginx -v 2>&1). Резервная копия: $BACKUP_DIR"
    if [ "$WAS_ACTIVE" = no ]; then info "До операции служба была остановлена; текущее состояние: $(systemctl is-active nginx 2>/dev/null || true)"; fi
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
        printf '1) Статус nginx, Docker и портов\n2) Проверить доступные обновления\n3) Обновить установленный nginx stable\n4) Обновить установленный nginx mainline\n5) Проверить nginx -t и подключённые конфиги\n6) Создать резервную копию\n7) Показать резервные копии\n8) Диагностика HTTP/2, портов и модулей\n9) Информация о nginx в Docker\n10) Новая установка системного nginx stable\n0) Выход\nВыбор: '
        read -r CHOICE || return 0
        case "$CHOICE" in
            1) status ;;
            2) check_updates ;;
            3) update_nginx stable update ;;
            4) printf 'Для перехода на mainline напиши MAINLINE: '; read -r CONFIRM || return 0; [ "$CONFIRM" = MAINLINE ] && update_nginx mainline update || info 'Отменено' ;;
            5) validate ;;
            6) backup ;;
            7) ls -lht "$BACKUP_ROOT" 2>/dev/null || info 'Резервных копий пока нет' ;;
            8) diagnose ;;
            9) docker_overview ;;
            10) printf 'Для новой установки системного nginx напиши INSTALL: '; read -r CONFIRM || return 0; [ "$CONFIRM" = INSTALL ] && update_nginx stable install || info 'Отменено' ;;
            0) return 0 ;;
            *) info 'Неизвестная команда' ;;
        esac
    done
}

usage() {
    cat <<'EOF'
nginx_updater — управляемое обновление системного nginx через nginx.org.
Запуск: sudo sh nginx-updater.sh [команда]
  --auto          Обновить установленный nginx; ветка nginx.org сохраняется (по умолчанию)
  --stable        Обновить установленный nginx stable
  --mainline      Обновить установленный nginx mainline
  --install       Установить системный nginx stable с нуля (не запускать, не включать)
  --menu          Интерактивное меню
  --status        Показать APT, Docker, процессы и порты
  --docker-status Обнаружить контейнеры с nginx и показать их версии/Compose
  --check         Обновить индексы APT и показать доступные версии
  --test          nginx -t для системного nginx и список конфигураций
  --diagnose      Проверка HTTP/2, модулей и прослушиваемых портов
  --backup        Создать резервную копию /etc/nginx
  --help          Показать справку

Безопасность: --auto больше НЕ устанавливает nginx, если его нет в APT.
При обнаружении nginx в Docker или других внешних процессах изменение системного пакета
блокируется. Контейнеры автоматически НЕ обновляются: нужно обновить тег образа/Compose.
Поддержка: Ubuntu 22.04/24.04/26.04, Debian 12/13; amd64/arm64.
EOF
}

case "${1:---auto}" in
    --auto) update_nginx "$(branch_from_repo)" update ;;
    --stable) update_nginx stable update ;;
    --mainline) update_nginx mainline update ;;
    --install) update_nginx stable install ;;
    --menu) menu ;;
    --status) status ;;
    --docker-status) docker_overview ;;
    --check) check_updates ;;
    --test) validate ;;
    --diagnose) diagnose ;;
    --backup) backup ;;
    --help|-h) usage ;;
    *) usage; exit 2 ;;
esac
 ||
            fail 'Разрешён только официальный образ nginx:X.Y.Z-alpine.'
        DOCKER_VERSION=${DOCKER_TARGET#nginx:}
        DOCKER_VERSION=${DOCKER_VERSION%-alpine}
    fi
    if dpkg --compare-versions "$DOCKER_VERSION" lt "$DOCKER_OLD_VERSION"; then
        fail "Новая версия $DOCKER_VERSION старее текущей $DOCKER_OLD_VERSION. Автоматическое понижение запрещено."
    fi
    info "Выбран образ: $DOCKER_TARGET"
    docker pull "$DOCKER_TARGET" || fail 'Не удалось скачать целевой образ.'
    DOCKER_CHECK_OUTPUT=$(docker run --rm --entrypoint nginx "$DOCKER_TARGET" -v 2>&1) ||
        fail 'Проверка версии целевого образа не прошла.'
    printf '%s\n' "$DOCKER_CHECK_OUTPUT" | grep -Fxq "nginx version: nginx/$DOCKER_VERSION" ||
        fail "Тег образа не соответствует ожидаемой версии: $DOCKER_CHECK_OUTPUT"

    DOCKER_OLD_ID=$(docker inspect -f '${.Image}' "$DOCKER_NAME")
    DOCKER_NEW_ID=$(docker image inspect -f '${.Id}' "$DOCKER_TARGET")
    if [ "$DOCKER_OLD_ID" = "$DOCKER_NEW_ID" ]; then
        info "Контейнер уже использует актуальные байты образа $DOCKER_TARGET. Ничего не изменяю."
        return 0
    fi

    umask 077
    DOCKER_BACKUP="$BACKUP_ROOT/docker/$DOCKER_NAME/$(date -u +%Y%m%dT%H%M%SZ)-$"
    mkdir -p "$DOCKER_BACKUP"
    cp -a "$DOCKER_WORKDIR" "$DOCKER_BACKUP/project" ||
        fail 'Не удалось сохранить резервную копию проекта.'
    cp -p "$DOCKER_COMPOSE_FILE" "$DOCKER_BACKUP/original-compose.yml" ||
        fail 'Не удалось сохранить Compose-файл.'
    docker inspect "$DOCKER_NAME" > "$DOCKER_BACKUP/container-inspect.json" ||
        fail 'Не удалось сохранить параметры контейнера.'
    printf '%s\n' "$DOCKER_OLD_IMAGE" > "$DOCKER_BACKUP/old-image.txt"
    info "Резерв проекта: $DOCKER_BACKUP"

    DOCKER_STAGE="$(dirname "$DOCKER_COMPOSE_FILE")/.nginx-updater.$.yml"
    [ ! -e "$DOCKER_STAGE" ] || fail 'Временный Compose-файл уже существует.'
    trap 'rm -f "$DOCKER_STAGE"' EXIT HUP INT TERM
    awk -v old="$DOCKER_OLD_IMAGE" -v new="$DOCKER_TARGET" '{
        line=$0; sub(/^[ \t]*/, "", line);
        if (line=="image: " old) {
            match($0, /^[ \t]*/);
            print substr($0,1,RLENGTH) "image: " new;
        } else print;
    }' "$DOCKER_COMPOSE_FILE" > "$DOCKER_STAGE" ||
        fail 'Не удалось создать временную конфигурацию.'

    docker compose -p "$DOCKER_PROJECT" --project-directory "$DOCKER_WORKDIR" -f "$DOCKER_STAGE" config -q ||
        fail 'Новая Compose-конфигурация некорректна; работающий контейнер не затронут.'
    docker compose -p "$DOCKER_PROJECT" --project-directory "$DOCKER_WORKDIR" -f "$DOCKER_STAGE" config --format json |
        python3 -c 'import json,sys; p=json.load(sys.stdin); s=p.get("services",{}).get(sys.argv[1],{}); sys.exit(0 if s.get("image")==sys.argv[2] else 1)' "$DOCKER_SERVICE" "$DOCKER_TARGET" ||
        fail 'Не удалось подтвердить новый образ в Compose.'

    info 'Проверяю новую конфигурацию nginx в одноразовом контейнере (без публикации портов).'
    docker compose -p "$DOCKER_PROJECT" --project-directory "$DOCKER_WORKDIR" -f "$DOCKER_STAGE" run --rm --no-deps --entrypoint nginx "$DOCKER_SERVICE" -t ||
        fail 'Проверка нового nginx -t завершилась ошибкой. Рабочий контейнер не изменён.'

    # Только после проверки записываем Compose и пересоздаём целевой сервис.
    cat "$DOCKER_STAGE" > "$DOCKER_COMPOSE_FILE" ||
        fail 'Не удалось записать новый Compose. Резерв сохранён.'
    rm -f "$DOCKER_STAGE"
    trap - EXIT HUP INT TERM
    info "Пересоздаю только сервис $DOCKER_SERVICE, не трогая зависимости."
    DOCKER_UPDATE_OK=no
    if docker compose -p "$DOCKER_PROJECT" --project-directory "$DOCKER_WORKDIR" -f "$DOCKER_COMPOSE_FILE" up -d --no-deps --force-recreate "$DOCKER_SERVICE"; then
        for RETRY in 1 2 3 4 5; do
            if [ "$(docker inspect -f '${.State.Running}' "$DOCKER_NAME" 2>/dev/null || true)" = true ] &&
               [ "$(docker inspect -f '${.Image}' "$DOCKER_NAME" 2>/dev/null || true)" = "$DOCKER_NEW_ID" ] &&
               docker exec "$DOCKER_NAME" nginx -t >/dev/null 2>&1; then
                DOCKER_UPDATE_OK=yes
                break
            fi
            sleep 1
        done
    fi
    if [ "$DOCKER_UPDATE_OK" != yes ]; then
        docker_update_rollback
        fail "Не удалось подтвердить запуск нового nginx. Проверь docker logs $DOCKER_NAME."
    fi
    info "Успешно: $(docker exec "$DOCKER_NAME" nginx -v 2>&1)"
    info "Обновлён только $DOCKER_NAME; резерв: $DOCKER_BACKUP"
    info 'Проверь HTTP/HTTPS на реальном домене и работу VPN извне. Смонтированные файлы вне проекта не резервировались.'
}

runtime_overview() {
    info 'Процессы nginx на хосте (с учётом контейнеров):'
    FOUND=no
    for PID in $(nginx_pids); do
        [ -d "/proc/$PID" ] || continue
        FOUND=yes
        printf '  PID %s: %s\n' "$PID" "$(nginx_process_origin "$PID")"
    done
    [ "$FOUND" = yes ] || info 'Процессы nginx не найдены.'
    info 'Слушающие TCP-порты 80/443:'
    if command -v ss >/dev/null 2>&1; then
        ss -H -lntp 2>/dev/null | awk '$4 ~ /:80$|:443$/ {print}' || true
    else
        info 'ss недоступен.'
    fi
    docker_overview
}

runtime_preflight() {
    MODE=$1
    if has_non_system_nginx || has_docker_nginx; then
        runtime_overview
        fail 'Обнаружен nginx, запущенный вне nginx.service (например, Docker). Не меняю системный пакет: это не обновит работающий контейнер. Используй --docker-status и проверь конфигурацию Compose.'
    fi
    if [ "$MODE" = install ]; then
        command -v ss >/dev/null 2>&1 || fail 'Не найден ss: нельзя безопасно проверить порты 80/443 перед установкой.'
        BUSY=$(ss -H -lntp 2>/dev/null | awk '$4 ~ /:80$|:443$/ {print}' || true)
        [ -z "$BUSY" ] || fail "Порты 80 или 443 уже заняты. Не устанавливаю дополнительный nginx:
$BUSY"
    fi
}

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
    if nginx_installed; then
        info 'Установленный системный nginx:'
        dpkg-query -W -f='Пакет: ${binary:Package} ${Version}\n' nginx
        if command -v nginx >/dev/null 2>&1; then nginx -v 2>&1; fi
    else
        info 'Системный пакет nginx через APT не установлен.'
        if command -v nginx >/dev/null 2>&1; then
            info 'Предупреждение: nginx найден в PATH, но не числится установленным через dpkg.'
            nginx -v 2>&1
        fi
    fi
    if command -v apt-cache >/dev/null 2>&1; then
        apt-cache policy nginx | sed -n '1,12p'
    fi
    if command -v systemctl >/dev/null 2>&1; then
        info "nginx.service: $(systemctl is-active nginx 2>/dev/null || true)"
        info "Автозапуск nginx.service: $(systemctl is-enabled nginx 2>/dev/null || true)"
    fi
    info "Ветка репозитория: $(branch_from_repo)"
    runtime_overview
}

validate() {
    command -v nginx >/dev/null 2>&1 || fail 'nginx не установлен'
    nginx -t
    info 'Активные конфигурационные файлы:'
    nginx -T 2>&1 | grep '^# configuration file ' || true
}

diagnose() {
    runtime_overview
    if nginx_installed; then
        validate
        info 'Настройки HTTP/2 в системном nginx:'
        nginx -T 2>&1 | grep -nE 'listen .*http2|^[[:space:]]*http2[[:space:]]+(on|off)' || true
        info 'Загруженные динамические модули:'
        nginx -T 2>&1 | grep -E '^[[:space:]]*load_module ' || true
    else
        info 'Системный nginx не установлен — проверка его nginx -t не выполняется.'
    fi
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
    ACTION=$2
    check_platform
    if command -v nginx >/dev/null 2>&1 && ! nginx_installed; then
        runtime_overview
        fail 'Найден nginx, не установленный через dpkg. Автоматическая установка/замена запрещена.'
    fi
    if [ "$ACTION" = update ] && ! nginx_installed; then
        runtime_overview
        fail 'Системного nginx нет. --auto не устанавливает второй nginx. Для новой установки без конфликтующих процессов используй --install.'
    fi
    if [ "$ACTION" = install ] && nginx_installed; then
        fail 'Системный nginx уже установлен. Используй --auto, --stable или --mainline.'
    fi
    runtime_preflight "$ACTION"
    if nginx_installed; then
        nginx -t || fail 'Текущая конфигурация содержит ошибки. Сначала исправь nginx -t.'
    fi
    check_modules_before_switch
    if apt-mark showhold | grep -qx nginx; then fail 'nginx находится на hold (apt-mark). Сними блокировку вручную.'; fi
    WAS_ACTIVE=no
    WAS_ENABLED=no
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet nginx; then WAS_ACTIVE=yes; fi
        if systemctl is-enabled --quiet nginx; then WAS_ENABLED=yes; fi
    fi
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
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
        if [ "$ACTION" = install ]; then
            # Установщик пакета может включить службу сам: отменяем это.
            systemctl disable --now nginx || fail 'Не удалось отключить автоматически созданную службу nginx.'
            info 'Новая установка: nginx.service отключён и не будет запускаться после перезагрузки.'
        elif [ "$WAS_ACTIVE" = yes ]; then
            systemctl restart nginx || fail 'nginx не запустился. Проверь journalctl -u nginx -n 100.'
            systemctl is-active --quiet nginx || fail 'nginx неактивен после обновления.'
        fi
        if [ "$ACTION" = update ] && [ "$WAS_ENABLED" = no ]; then
            systemctl disable nginx || fail 'Не удалось сохранить отключённый автозапуск nginx.'
            if [ "$WAS_ACTIVE" = no ] && systemctl is-active --quiet nginx; then
                systemctl stop nginx || fail 'nginx неожиданно запустился во время обновления, не удалось его остановить.'
            fi
        fi
    fi
    info "Успешно: $(nginx -v 2>&1). Резервная копия: $BACKUP_DIR"
    if [ "$WAS_ACTIVE" = no ]; then info "До операции служба была остановлена; текущее состояние: $(systemctl is-active nginx 2>/dev/null || true)"; fi
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
        printf '1) Статус nginx, Docker и портов\n2) Проверить доступные обновления\n3) Обновить установленный nginx stable\n4) Обновить установленный nginx mainline\n5) Проверить nginx -t и подключённые конфиги\n6) Создать резервную копию\n7) Показать резервные копии\n8) Диагностика HTTP/2, портов и модулей\n9) Информация о nginx в Docker\n10) Новая установка системного nginx stable\n0) Выход\nВыбор: '
        read -r CHOICE || return 0
        case "$CHOICE" in
            1) status ;;
            2) check_updates ;;
            3) update_nginx stable update ;;
            4) printf 'Для перехода на mainline напиши MAINLINE: '; read -r CONFIRM || return 0; [ "$CONFIRM" = MAINLINE ] && update_nginx mainline update || info 'Отменено' ;;
            5) validate ;;
            6) backup ;;
            7) ls -lht "$BACKUP_ROOT" 2>/dev/null || info 'Резервных копий пока нет' ;;
            8) diagnose ;;
            9) docker_overview ;;
            10) printf 'Для новой установки системного nginx напиши INSTALL: '; read -r CONFIRM || return 0; [ "$CONFIRM" = INSTALL ] && update_nginx stable install || info 'Отменено' ;;
            0) return 0 ;;
            *) info 'Неизвестная команда' ;;
        esac
    done
}

usage() {
    cat <<'EOF'
nginx_updater — управляемое обновление системного nginx через nginx.org.
Запуск: sudo sh nginx-updater.sh [команда]
  --auto          Обновить установленный nginx; ветка nginx.org сохраняется (по умолчанию)
  --stable        Обновить установленный nginx stable
  --mainline      Обновить установленный nginx mainline
  --install       Установить системный nginx stable с нуля (не запускать, не включать)
  --menu          Интерактивное меню
  --status        Показать APT, Docker, процессы и порты
  --docker-status Обнаружить контейнеры с nginx и показать их версии/Compose
  --check         Обновить индексы APT и показать доступные версии
  --test          nginx -t для системного nginx и список конфигураций
  --diagnose      Проверка HTTP/2, модулей и прослушиваемых портов
  --backup        Создать резервную копию /etc/nginx
  --help          Показать справку

Безопасность: --auto больше НЕ устанавливает nginx, если его нет в APT.
При обнаружении nginx в Docker или других внешних процессах изменение системного пакета
блокируется. Контейнеры автоматически НЕ обновляются: нужно обновить тег образа/Compose.
Поддержка: Ubuntu 22.04/24.04/26.04, Debian 12/13; amd64/arm64.
EOF
}

case "${1:---auto}" in
    --auto) update_nginx "$(branch_from_repo)" update ;;
    --stable) update_nginx stable update ;;
    --mainline) update_nginx mainline update ;;
    --install) update_nginx stable install ;;
    --menu) menu ;;
    --status) status ;;
    --docker-status) docker_overview ;;
    --check) check_updates ;;
    --test) validate ;;
    --diagnose) diagnose ;;
    --backup) backup ;;
    --help|-h) usage ;;
    *) usage; exit 2 ;;
esac
