#!/bin/sh
# nginx_updater: safely detects and updates the active APT or Docker Compose nginx.
set -eu

VERSION=1.3.1
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


# Docker Compose nginx update: explicit by name or selected by --auto when unambiguous.
docker_rollback() {
    info "Проверка после обновления не прошла; возвращаю $OLD_IMAGE."
    if cp -p "$BACKUP_DIR/original-compose.yml" "$COMPOSE_FILE" &&
       docker compose -p "$PROJECT" --project-directory "$WORKDIR" -f "$COMPOSE_FILE" up -d --no-deps --force-recreate "$SERVICE" &&
       docker exec "$CONTAINER" nginx -t; then
        info "Откат выполнен. Резервная копия: $BACKUP_DIR"
    else
        info "ОШИБКА ОТКАТА. Ручное восстановление из $BACKUP_DIR"
    fi
}
docker_compose_check_image() {
    # Refuse to change a similarly named service or ambiguous Compose YAML.
    docker compose -p "$PROJECT" --project-directory "$WORKDIR" -f "$1" config --format json |
        python3 -c 'import json,sys; x=json.load(sys.stdin); s=x.get("services",{}).get(sys.argv[1],{}); sys.exit(0 if s.get("image")==sys.argv[2] else 1)' "$SERVICE" "$2"
}
docker_update() {
    need_root
    CONTAINER=${1:-}
    REQUESTED=${2:-}
    [ -n "$CONTAINER" ] || fail 'Нужен контейнер: --docker-update nginx-selfsteal [nginx:1.30.7-alpine]'
    printf '%s' "$CONTAINER" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]*$' || fail 'Некорректное имя контейнера.'
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || fail 'Docker недоступен.'
    docker compose version >/dev/null 2>&1 || fail 'Необходим Docker Compose v2.'
    command -v python3 >/dev/null 2>&1 || fail 'Необходим python3 для проверки Compose.'
    command -v dpkg >/dev/null 2>&1 || fail 'Необходим dpkg для сравнения версий.'
    RUNNING=$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)
    [ "$RUNNING" = true ] || fail "Контейнер $CONTAINER не запущен."
    WORKDIR=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$CONTAINER")
    COMPOSE_FILE=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$CONTAINER")
    PROJECT=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$CONTAINER")
    SERVICE=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$CONTAINER")
    case "$WORKDIR" in /*) ;; *) fail 'У контейнера нет корректной рабочей директории Compose.' ;; esac
    case "$COMPOSE_FILE" in /*) ;; *) fail 'Не удалось определить абсолютный путь к Compose-файлу.' ;; esac
    case "$COMPOSE_FILE" in *,*) fail 'Многосоставные Compose-проекты пока не поддерживаются.' ;; esac
    [ -f "$COMPOSE_FILE" ] && [ ! -L "$COMPOSE_FILE" ] || fail 'Compose-файл отсутствует или является ссылкой.'
    [ -d "$WORKDIR" ] || fail 'Директория Compose отсутствует.'
    printf '%s' "$PROJECT" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]*$' || fail 'Некорректная метка Compose-проекта.'
    printf '%s' "$SERVICE" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]*$' || fail 'Некорректная метка Compose-сервиса.'
    OLD_IMAGE=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER")
    printf '%s' "$OLD_IMAGE" | grep -Eq '^nginx:[0-9]+\.[0-9]+\.[0-9]+-alpine$' ||
        fail "Для обновления поддерживается только официальный nginx:X.Y.Z-alpine, сейчас: $OLD_IMAGE"
    OLD_VERSION=${OLD_IMAGE#nginx:}
    OLD_VERSION=${OLD_VERSION%-alpine}
    info "Контейнер $CONTAINER (сервис $SERVICE), образ $OLD_IMAGE"
    info "Compose: $COMPOSE_FILE"
    docker compose -p "$PROJECT" --project-directory "$WORKDIR" -f "$COMPOSE_FILE" config -q ||
        fail 'Исходный Compose не проходит проверку.'
    docker_compose_check_image "$COMPOSE_FILE" "$OLD_IMAGE" ||
        fail 'Образ сервиса в Compose не совпадает с текущим контейнером.'
    docker exec "$CONTAINER" nginx -t || fail 'Текущий nginx -t не проходит.'
    MATCHES=$(awk -v old="$OLD_IMAGE" '{s=$0;sub(/^[ \t]*/,"",s);if(s=="image: " old)n++}END{print n+0}' "$COMPOSE_FILE")
    [ "$MATCHES" -eq 1 ] || fail 'Не найдена ровно одна строка image: старый-образ. Сложный Compose не изменяю.'
    if [ -n "$REQUESTED" ]; then
        TARGET=$REQUESTED
        printf '%s' "$TARGET" | grep -Eq '^nginx:[0-9]+\.[0-9]+\.[0-9]+-alpine$' ||
            fail 'Допустим только тег nginx:X.Y.Z-alpine.'
        NEW_VERSION=${TARGET#nginx:}
        NEW_VERSION=${NEW_VERSION%-alpine}
    else
        info 'Ищу актуальный nginx stable-alpine в официальном Docker Hub.'
        docker pull nginx:stable-alpine || fail 'Не удалось скачать stable-alpine.'
        VER_OUTPUT=$(docker run --rm --entrypoint nginx nginx:stable-alpine -v 2>&1) ||
            fail 'Не удалось определить версию stable-alpine.'
        NEW_VERSION=$(printf '%s\n' "$VER_OUTPUT" | sed -n 's/^nginx version: nginx\/\([0-9][0-9.]*\)$/\1/p' | head -n 1)
        [ -n "$NEW_VERSION" ] || fail "Неожиданный ответ образа: $VER_OUTPUT"
        TARGET="nginx:$NEW_VERSION-alpine"
    fi
    if dpkg --compare-versions "$NEW_VERSION" lt "$OLD_VERSION"; then
        fail "Нельзя автоматически понижать nginx $OLD_VERSION -> $NEW_VERSION."
    fi
    docker pull "$TARGET" || fail "Не удалось скачать $TARGET."
    VER_OUTPUT=$(docker run --rm --entrypoint nginx "$TARGET" -v 2>&1) || fail 'Невозможно проверить скачанный образ.'
    printf '%s\n' "$VER_OUTPUT" | grep -Fxq "nginx version: nginx/$NEW_VERSION" ||
        fail "Содержимое $TARGET не совпадает с ожидаемой версией: $VER_OUTPUT"
    OLD_ID=$(docker inspect -f '{{.Image}}' "$CONTAINER")
    TARGET_ID=$(docker image inspect -f '{{.Id}}' "$TARGET")
    if [ "$OLD_ID" = "$TARGET_ID" ]; then
        info "Уже используется актуальный образ ($TARGET), обновлять нечего."
        return 0
    fi
    umask 077
    BACKUP_DIR="$BACKUP_ROOT/docker/$CONTAINER/$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir -p "$BACKUP_DIR"
    cp -a "$WORKDIR" "$BACKUP_DIR/project" || fail 'Резервирование проекта не удалось.'
    cp -p "$COMPOSE_FILE" "$BACKUP_DIR/original-compose.yml" || fail 'Резервирование Compose не удалось.'
    docker inspect "$CONTAINER" > "$BACKUP_DIR/inspect.json" || fail 'Резервирование параметров контейнера не удалось.'
    printf '%s\n' "$OLD_IMAGE" > "$BACKUP_DIR/old-image.txt"
    info "Резервная копия: $BACKUP_DIR"
    STAGE="$(dirname "$COMPOSE_FILE")/.nginx-updater.$$.yml"
    [ ! -e "$STAGE" ] || fail 'Временный файл уже существует.'
    trap 'rm -f "$STAGE"' 0 1 2 15
    awk -v old="$OLD_IMAGE" -v new="$TARGET" '{
        s=$0;sub(/^[ \t]*/,"",s);
        if (s=="image: " old) {match($0,/^[ \t]*/); print substr($0,1,RLENGTH) "image: " new}
        else print
    }' "$COMPOSE_FILE" > "$STAGE" || fail 'Не удалось подготовить новый Compose.'
    docker compose -p "$PROJECT" --project-directory "$WORKDIR" -f "$STAGE" config -q ||
        fail 'Новый Compose не проходит проверку. Работающий nginx не затронут.'
    docker_compose_check_image "$STAGE" "$TARGET" ||
        fail 'Образ в новом Compose отличается от ожидаемого.'
    info 'Тестирую nginx -t в одноразовом контейнере (без портов и зависимостей).'
    docker compose -p "$PROJECT" --project-directory "$WORKDIR" -f "$STAGE" run --rm --no-deps --entrypoint nginx "$SERVICE" -t ||
        fail 'nginx -t с новым образом не проходит. Рабочий контейнер не затронут.'
    chmod --reference="$COMPOSE_FILE" "$STAGE"
    chown --reference="$COMPOSE_FILE" "$STAGE"
    mv -f "$STAGE" "$COMPOSE_FILE" || fail "Не удалось заменить Compose. Резерв: $BACKUP_DIR"
    trap - 0 1 2 15
    info "Пересоздаю только сервис $SERVICE с образом $TARGET."
    UPDATED=no
    if docker compose -p "$PROJECT" --project-directory "$WORKDIR" -f "$COMPOSE_FILE" up -d --no-deps --force-recreate "$SERVICE"; then
        for TRY in 1 2 3 4 5; do
            ACTUAL_RUNNING=$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)
            ACTUAL_ID=$(docker inspect -f '{{.Image}}' "$CONTAINER" 2>/dev/null || true)
            if [ "$ACTUAL_RUNNING" = true ] && [ "$ACTUAL_ID" = "$TARGET_ID" ] &&
               docker exec "$CONTAINER" nginx -t >/dev/null 2>&1; then
                UPDATED=yes
                break
            fi
            sleep 1
        done
    fi
    if [ "$UPDATED" != yes ]; then
        docker_rollback
        fail 'Не удалось подтвердить работу обновлённого nginx.'
    fi
    info "Готово: $(docker exec "$CONTAINER" nginx -v 2>&1)"
    info "Обновлён только контейнер $CONTAINER. Резерв: $BACKUP_DIR"
    info 'Проверь сайт и VPN извне. Файлы, смонтированные вне каталога проекта, не резервировались.'
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
    # Не допускаем ложных отрицательных результатов при недоступном Docker daemon.
    if command -v docker >/dev/null 2>&1; then
        docker info >/dev/null 2>&1 ||
            fail 'Docker установлен, но daemon недоступен. Проверка параллельных nginx невозможна.'
        docker ps --format '{{.Names}}|{{.Image}}' >/dev/null 2>&1 ||
            fail 'Не удалось получить список Docker-контейнеров.'
    fi

    CONTAINER_NGINX=no
    if has_docker_nginx; then CONTAINER_NGINX=yes; fi

    # Обход по процессам необходим: имя Docker-контейнера может не содержать "nginx".
    for CHECK_PID in $(nginx_pids); do
        [ -d "/proc/$CHECK_PID" ] || continue
        CHECK_ORIGIN=$(nginx_process_origin "$CHECK_PID")
        case "$CHECK_ORIGIN" in
            systemd) ;;
            container) CONTAINER_NGINX=yes ;;
            *)
                runtime_overview
                fail "nginx PID=$CHECK_PID запущен вне nginx.service/Docker (тип: $CHECK_ORIGIN). Обновление системного пакета небезопасно."
                ;;
        esac
    done

    if [ "$MODE" = install ]; then
        [ "$CONTAINER_NGINX" = no ] ||
            fail 'Работает контейнерный nginx. Не устанавливаю второй системный nginx.'
        command -v ss >/dev/null 2>&1 ||
            fail 'Не найден ss: нельзя безопасно проверить порты 80/443 перед установкой.'
        BUSY=$(ss -H -lntp 2>/dev/null | awk '$4 ~ /:80$|:443$/ {print}' || true)
        [ -z "$BUSY" ] || fail "Порты 80 или 443 уже заняты. Не устанавливаю дополнительный nginx:
$BUSY"
    elif [ "$MODE" = update ] && [ "$CONTAINER_NGINX" = yes ]; then
        # На нодах с CDN (nginx.service) и Selfsteal (Docker) обновляем только
        # уже работающий системный nginx. Не запускаем неиспользуемый пакет.
        if ! command -v systemctl >/dev/null 2>&1 ||
           ! systemctl is-active --quiet nginx; then
            runtime_overview
            fail 'Есть Docker-nginx, но системный nginx.service не активен. Не обновляю неиспользуемый APT-пакет.'
        fi
        info 'Обнаружен также Docker-nginx. Обновляю ТОЛЬКО активный системный nginx; Docker не изменяю.'
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

# Автоматически определяем, какой nginx РЕАЛЬНО используется на сервере.
# Если есть неопределённость, не меняем ни APT, ни Docker.
auto_update() {
    need_root
    info 'Определяю активный nginx: системная служба или Docker.'
    DOCKER_CANDIDATES=
    if command -v docker >/dev/null 2>&1; then
        docker info >/dev/null 2>&1 || fail 'Docker установлен, но daemon недоступен. Не могу проверить контейнеры безопасно.'
        DOCKER_PS=$(docker ps --format '{{.Names}}|{{.Image}}') ||
            fail 'Не удалось получить список контейнеров Docker.'
        DOCKER_CANDIDATES=$(printf '%s\n' "$DOCKER_PS" |
            awk -F'|' 'tolower($1 "|" $2) ~ /nginx/ {print $1}')
    fi
    SYSTEM_ACTIVE=no
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
        SYSTEM_ACTIVE=yes
    fi
    COUNT=0
    if [ -n "$DOCKER_CANDIDATES" ]; then
        COUNT=$(printf '%s\n' "$DOCKER_CANDIDATES" | awk 'NF {n++} END {print n+0}')
    fi
    if [ "$COUNT" -gt 1 ]; then
        runtime_overview
        fail 'Найдено несколько nginx-контейнеров. Укажи нужный: --docker-update ИМЯ.'
    fi
    if [ "$COUNT" -eq 1 ]; then
        if [ "$SYSTEM_ACTIVE" = yes ]; then
            runtime_overview
            fail 'Работают и nginx.service, и nginx в Docker. Выбери --stable (APT) или --docker-update ИМЯ.'
        fi
        # Не пропускаем nginx, запущенный нестандартным способом вне выбранного контейнера.
        for PID in $(nginx_pids); do
            [ -d "/proc/$PID" ] || continue
            ORIGIN=$(nginx_process_origin "$PID")
            [ "$ORIGIN" = container ] || {
                runtime_overview
                fail "Помимо Docker обнаружен ещё nginx PID=$PID ($ORIGIN). Нужен явный выбор."
            }
        done
        SELECTED=$(printf '%s\n' "$DOCKER_CANDIDATES" | awk 'NF {print; exit}')
        info "Выбран работающий Docker-nginx: $SELECTED. APT-пакет менять не буду."
        docker_update "$SELECTED" ""
        return
    fi
    # Если контейнер не найден, но nginx есть вне systemd, нельзя делать вид,
    # что это запущенный системный пакет nginx.
    if has_non_system_nginx; then
        runtime_overview
        fail 'Найден nginx вне systemd nginx.service, но его контейнер не опознан. Автоматически не обновляю.'
    fi
    if nginx_installed; then
        info 'Найден установленный системный nginx. Использую APT.'
        update_nginx "$(branch_from_repo)" update
        return
    fi
    runtime_overview
    fail 'Не найден однозначный nginx для обновления. Для новой установки системного nginx используй --install.'
}

check_updates() {
    need_root
    apt-get update
    status
}

menu() {
    while :; do
        printf '\n===== nginx_updater %s =====\n' "$VERSION"
        printf '1) Статус nginx, Docker и портов\n2) Проверить доступные обновления\n3) Обновить установленный nginx stable\n4) Обновить установленный nginx mainline\n5) Проверить nginx -t и подключённые конфиги\n6) Создать резервную копию\n7) Показать резервные копии\n8) Диагностика HTTP/2, портов и модулей\n9) Информация о nginx в Docker\n10) Новая установка системного nginx stable\n11) Обновить nginx в Docker\n12) Автоматически обновить работающий nginx (APT или Docker)\n0) Выход\nВыбор: '
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
            11) printf 'Имя nginx-контейнера: '; read -r D_NAME || return 0; printf 'Тег (Enter = последняя stable-alpine): '; read -r D_TARGET || return 0; docker_update "$D_NAME" "$D_TARGET" ;;
            12) auto_update ;;
            0) return 0 ;;
            *) info 'Неизвестная команда' ;;
        esac
    done
}

usage() {
    cat <<'EOF'
nginx_updater — автоопределение активного nginx (APT или Docker Compose).
Запуск: sudo sh nginx-updater.sh [команда]
  --auto          Найти активный nginx и обновить через APT или Docker Compose (по умолчанию)
  --stable        Обновить установленный nginx stable
  --mainline      Обновить установленный nginx mainline
  --install       Установить системный nginx stable с нуля (не запускать, не включать)
  --menu          Интерактивное меню
  --status        Показать APT, Docker, процессы и порты
  --docker-status Обнаружить контейнеры с nginx и показать их версии/Compose
  --docker-update NAME [IMAGE] Обновить выбранный Compose-контейнер nginx до stable-alpine
                               либо до указанной версии nginx:X.Y.Z-alpine
  --check         Обновить индексы APT и показать доступные версии
  --test          nginx -t для системного nginx и список конфигураций
  --diagnose      Проверка HTTP/2, модулей и прослушиваемых портов
  --backup        Создать резервную копию /etc/nginx
  --help          Показать справку

Безопасность: --auto выбирает APT или единственный nginx-контейнер Docker.
Если несколько активных nginx или неоднозначная установка, прекращает работу.
Новая установка системного nginx только через --install. Docker можно обновить явно.
Поддержка: Ubuntu 22.04/24.04/26.04, Debian 12/13; amd64/arm64.
EOF
}

case "${1:---auto}" in
    --auto) auto_update ;;
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
