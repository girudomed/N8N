#!/bin/bash

set -Eeuo pipefail

# --- defaults for flags (safe when running with 'set -u') ---
: "${RUN_FROM_CRON:=0}"
: "${SKIP_BACKUP:=0}"
: "${FORCE:=0}"

# === базовые настройки (переопределяемы переменными окружения) ===
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

LOG="${LOG:-/var/log/n8n-nightly-update.log}"
COMPOSE_DIR="${COMPOSE_DIR:-/root/N8N}"                 # каталог с docker-compose.yml
COMPOSE_FILE="${COMPOSE_FILE:-$COMPOSE_DIR/docker-compose.yml}"
DATA_DIR="${DATA_DIR:-/root/n8n_data}"                  # том с данными n8n
BACKUP_DIR="${BACKUP_DIR:-/root/n8n_backups}"
LOCK_FILE="${LOCK_FILE:-$DATA_DIR/update.lock}"
IMAGE_REPO="${IMAGE_REPO:-n8nio/n8n:latest}"            # базовый ообраз в Dockerfile
RETAIN_DAYS="${RETAIN_DAYS:-30}"                        # хранить бэкапы N дней
HOST_DOMAIN="${HOST_DOMAIN:-}"                           # если задан — делаем HTTP healthcheck через Caddy
HEALTHCHECK=1                                            # можно выключить флагом --no-health

usage() {
  cat <<'USAGE'
Usage: update-n8n.sh [--cron] [--skip-backup] [--force] [--compose-dir PATH] [--compose-file FILE] [--no-health] [--host-domain URL]
  --cron          помечает запуск из cron (для логов)
  --skip-backup   пропустить архивирование DATA_DIR
  --force         игнорировать существующий lock-файл
  --compose-dir   путь к каталогу с docker-compose.yml (по умолчанию /root/N8N)
  --compose-file  явный путь к docker-compose.yml
  --no-health     не выполнять HTTP healthcheck после запуска контейнеров
  --host-domain   домен для healthcheck (например, https://n8n.portalgm.ru). Можно задать переменной HOST_DOMAIN
env:
  LOG, COMPOSE_DIR, COMPOSE_FILE, DATA_DIR, BACKUP_DIR, LOCK_FILE, IMAGE_REPO, RETAIN_DAYS, HOST_DOMAIN — можно задать через окружение
USAGE
}

# --- разбор аргументов ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cron) RUN_FROM_CRON=1; shift ;;
    --skip-backup) SKIP_BACKUP=1; shift ;;
    --force) FORCE=1; shift ;;
    --compose-dir) COMPOSE_DIR="$2"; COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"; shift 2 ;;
    --compose-file) COMPOSE_FILE="$2"; COMPOSE_DIR="$(dirname "$2")"; shift 2 ;;
    --no-health) HEALTHCHECK=0; shift ;;
    --host|--host-domain) HOST_DOMAIN="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 2 ;;
  esac
done

# --- утилиты ---
ts() { date '+%F %T'; }
log() { echo "[$(ts)] $*" | tee -a "$LOG"; }

# --- проверки окружения ---
if [[ $EUID -ne 0 ]]; then
  echo "нужны права root" >&2; exit 1
fi

mkdir -p "$(dirname "$LOG")" "$BACKUP_DIR"
touch "$LOG" && chmod 0644 "$LOG" || { echo "не могу писать в $LOG" >&2; exit 1; }

if [[ ! -f "$COMPOSE_FILE" ]]; then
  log "ERROR: не найден $COMPOSE_FILE (COMPOSE_DIR=$COMPOSE_DIR)"; exit 1
fi

DOCKER="$(command -v docker || true)"
if [[ -z "$DOCKER" ]]; then
  log "ERROR: docker не найден в PATH"; exit 1
fi

# Определяем docker compose (v2 плагин или v1 бинарь)
if $DOCKER compose version >/dev/null 2>&1; then
  COMPOSE_IS_PLUGIN=1
  COMPOSE_BIN="$DOCKER"
  COMPOSE_ARGS=(compose -f "$COMPOSE_FILE")
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_IS_PLUGIN=0
  COMPOSE_BIN="$(command -v docker-compose)"
  COMPOSE_ARGS=(-f "$COMPOSE_FILE")
else
  log "ERROR: не найден ни 'docker compose', ни 'docker-compose'"; exit 1
fi

log "=== START n8n update (cron=$RUN_FROM_CRON) ==="
log "compose_file=$COMPOSE_FILE | data_dir=$DATA_DIR | backup_dir=$BACKUP_DIR | image_repo=$IMAGE_REPO | host_domain=${HOST_DOMAIN:-<unset>} | health=${HEALTHCHECK}"

# --- блокировка ---
if [[ -e "$LOCK_FILE" && $FORCE -eq 0 ]]; then
  log "Lock $LOCK_FILE существует — выходим (используй --force, если уверен)"
  exit 1
fi
mkdir -p "$(dirname "$LOCK_FILE")"
: > "$LOCK_FILE"
trap 'rc=$?; rm -f "$LOCK_FILE"; log "Lock удалён. Выход с кодом $rc"; exit $rc' EXIT

# --- бэкап данных (с анти-спамом: не дублируем за текущую дату) ---
TODAY="$(date +%F)"
DATA_BACKUP_EXISTS="$(ls -1 "$BACKUP_DIR"/n8n_data_"$TODAY"_*.tar.gz 2>/dev/null | head -n1 || true)"
IMAGE_BACKUP_EXISTS="$(ls -1 "$BACKUP_DIR"/n8n_image_"$TODAY"_*.tar.gz 2>/dev/null | head -n1 || true)"
SKIP_BACKUP_TODAY=0
SKIP_IMAGE_BACKUP_TODAY=0
[[ -n "$DATA_BACKUP_EXISTS" ]] && SKIP_BACKUP_TODAY=1
[[ -n "$IMAGE_BACKUP_EXISTS" ]] && SKIP_IMAGE_BACKUP_TODAY=1

if [[ $SKIP_BACKUP -eq 0 && $SKIP_BACKUP_TODAY -eq 0 ]]; then
  if [[ -d "$DATA_DIR" ]]; then
    ARCHIVE="$BACKUP_DIR/n8n_data_$(date +'%F_%H%M%S').tar.gz"
    log "Создаю бэкап $DATA_DIR -> $ARCHIVE"
    if ! tar -C "$(dirname "$DATA_DIR")" -czf "$ARCHIVE" "$(basename "$DATA_DIR")" >>"$LOG" 2>&1; then
      log "WARNING: бэкап данных не удался — продолжу (данные НЕ трогаю)"
    fi
  else
    log "WARNING: $DATA_DIR не найден — бэкап пропущен"
  fi
elif [[ $SKIP_BACKUP -eq 1 ]]; then
  log "Бэкап пропущен по флагу --skip-backup"
else
  log "Бэкап пропущен — уже есть архив за $TODAY"
fi

# --- резерв текущего образа контейнера (для отката) ---
if [[ $SKIP_BACKUP -eq 1 ]]; then
  log "Снапшот образа пропущен по флагу --skip-backup"
elif [[ $SKIP_IMAGE_BACKUP_TODAY -eq 1 ]]; then
  log "Снапшот образа пропущен — уже есть архив за $TODAY"
else
  TIMESTAMP="$(date +'%F_%H%M%S')"
  BACKUP_IMG_TAG="n8n_backup:${TIMESTAMP}"
  N8N_CID_FROM_COMPOSE="$("$COMPOSE_BIN" "${COMPOSE_ARGS[@]}" ps -q n8n 2>/dev/null || true)"
  if [[ -n "$N8N_CID_FROM_COMPOSE" ]]; then
    N8N_CONTAINER="$N8N_CID_FROM_COMPOSE"
  else
    # fallback: ищем по имени контейнера
    N8N_CONTAINER="$($DOCKER ps --filter "name=n8n_n8n_1" --format '{{.ID}}' | head -n1 || true)"
    [[ -z "$N8N_CONTAINER" ]] && N8N_CONTAINER="$($DOCKER ps --format '{{.ID}} {{.Names}}' | awk '/(^|_)n8n(_|$)|(^|-)n8n(-|$)/{print $1; exit}')"
  fi

  if [[ -n "$N8N_CONTAINER" ]]; then
    CURRENT_IMG_ID="$($DOCKER inspect --format='{{.Image}}' "$N8N_CONTAINER" 2>/dev/null || true)"
    if [[ -n "$CURRENT_IMG_ID" ]]; then
      CURRENT_REPOTAG="$($DOCKER images --no-trunc --format '{{.Repository}}:{{.Tag}} {{.ID}}' | awk -v id="$CURRENT_IMG_ID" '$2==id{print $1; exit}')"
      if [[ -n "$CURRENT_REPOTAG" ]]; then
        log "Резервирую образ $CURRENT_REPOTAG как $BACKUP_IMG_TAG"
        $DOCKER tag "$CURRENT_REPOTAG" "$BACKUP_IMG_TAG" || true
      else
        log "Резервирую image-id $CURRENT_IMG_ID как $BACKUP_IMG_TAG"
        $DOCKER tag "$CURRENT_IMG_ID" "$BACKUP_IMG_TAG" || true
      fi
      BACKUP_IMAGE_TAR="$BACKUP_DIR/n8n_image_${TIMESTAMP}.tar.gz"
      log "Сохраняю образ в $BACKUP_IMAGE_TAR"
      if ! $DOCKER save "$BACKUP_IMG_TAG" | gzip > "$BACKUP_IMAGE_TAR" 2>>"$LOG"; then
        log "WARNING: docker save не удался (образ резервно протегирован)"
      fi
    else
      log "WARNING: не удалось получить Image ID контейнера $N8N_CONTAINER"
    fi
  else
    log "WARNING: контейнер n8n не найден — резерв образа пропущен"
  fi
fi

# --- подтягиваем образ, указанный в Dockerfile (если найден), иначе $IMAGE_REPO ---
PULL_IMAGE="$IMAGE_REPO"
DF_PATH_GUESS="$(awk -v RS='\0' 'match($0, /dockerfile:[[:space:]]*([^\n]+)/, a){print a[1]}' "$COMPOSE_FILE" 2>/dev/null || true)"
[[ -z "$DF_PATH_GUESS" ]] && DF_PATH_GUESS="$COMPOSE_DIR/Dockerfile"
if [[ -f "$DF_PATH_GUESS" ]]; then
  FROM_IMG="$(awk 'BEGIN{IGNORECASE=1} $1==\"FROM\"{print $2; exit}' "$DF_PATH_GUESS" 2>/dev/null || true)"
  [[ -n "$FROM_IMG" ]] && PULL_IMAGE="$FROM_IMG"
fi

# Robust docker pull with retries and extended diagnostics
PULL_ATTEMPTS="${PULL_ATTEMPTS:-3}"
PULL_DELAY_SECONDS="${PULL_DELAY_SECONDS:-5}"
PULL_OK=0

log "docker pull $PULL_IMAGE (will try up to $PULL_ATTEMPTS times)"
for i in $(seq 1 "$PULL_ATTEMPTS"); do
  log "docker pull attempt $i/$PULL_ATTEMPTS: pulling $PULL_IMAGE"
  if $DOCKER pull "$PULL_IMAGE" >>"$LOG" 2>&1; then
    log "docker pull succeeded on attempt $i"
    PULL_OK=1
    break
  else
    log "WARNING: docker pull attempt $i failed"
    # collect immediate diagnostics after a failed attempt
    log "Collecting docker diagnostics (version/info) for attempt $i"
    $DOCKER version >>"$LOG" 2>&1 || true
    $DOCKER info >>"$LOG" 2>&1 || true
    if [[ $i -lt "$PULL_ATTEMPTS" ]]; then
      sleep_time=$((PULL_DELAY_SECONDS * i))
      log "Waiting ${sleep_time}s before next attempt..."
      sleep "$sleep_time"
    fi
  fi
done

if [[ $PULL_OK -ne 1 ]]; then
  log "ERROR: docker pull $PULL_IMAGE не удался после $PULL_ATTEMPTS попыток"
  log "Последние строки /var/log/docker (journal) и свободное место могут помочь в диагностике."
  # Try to append some useful system-level diagnostics to the log (best-effort)
  if command -v journalctl >/dev/null 2>&1; then
    log "Appending last 200 lines of docker service journal"
    journalctl -u docker --no-pager -n 200 >>"$LOG" 2>&1 || true
  fi
  df -h >>"$LOG" 2>&1 || true
  $DOCKER system df >>"$LOG" 2>&1 || true
  exit 1
fi

# --- остановка сервисов (без удаления томов!) ---
cd "$COMPOSE_DIR"
log "Останавливаю сервисы: docker compose down"
if ! "$COMPOSE_BIN" "${COMPOSE_ARGS[@]}" down >>"$LOG" 2>&1; then
  log "WARNING: down завершился с ошибкой, продолжаю"
fi

# --- сборка (на свежей базе) ---
log "Собираю сервисы: build --pull --no-cache"
if ! "$COMPOSE_BIN" "${COMPOSE_ARGS[@]}" build --pull --no-cache >>"$LOG" 2>&1; then
  log "ERROR: build завершился с ошибкой"; exit 1
fi

# --- запуск ---
log "Поднимаю сервисы: up -d"
if ! "$COMPOSE_BIN" "${COMPOSE_ARGS[@]}" up -d >>"$LOG" 2>&1; then
  log "ERROR: up -d завершился с ошибкой"; exit 1
fi

# --- проверка и версия n8n ---
sleep 5
N8N_CID="$("$COMPOSE_BIN" "${COMPOSE_ARGS[@]}" ps -q n8n 2>/dev/null || true)"
if [[ -z "$N8N_CID" ]]; then
  N8N_CID="$($DOCKER ps -q --format '{{.ID}} {{.Names}}' | awk '/(^|_)n8n(_|$)|(^|-)n8n(-|$)/{print $1; exit}')"
fi

if [[ -n "$N8N_CID" ]]; then
  log "Контейнер n8n: $N8N_CID"
  $DOCKER exec -i "$N8N_CID" n8n --version >>"$LOG" 2>&1 || log "WARNING: не удалось получить версию n8n внутри контейнера"
else
  log "WARNING: контейнер n8n не найден после запуска"
fi

# --- HEALTHCHECK (опционально) ---
if [[ "$HEALTHCHECK" -eq 1 && -n "${HOST_DOMAIN}" ]]; then
  log "HEALTHCHECK phase1: проверяю Caddy ${HOST_DOMAIN}/health"
  PH1_OK=0
  for i in {1..20}; do
    if curl -fsSIL --max-time 5 "${HOST_DOMAIN}/health" >/dev/null 2>&1; then
      log "HEALTHCHECK: /health -> 200 (Caddy OK)"
      PH1_OK=1
      break
    fi
    log "HEALTHCHECK: /health not ready yet (try $i/20), wait 5s..."
    sleep 5
  done
  if [[ $PH1_OK -ne 1 ]]; then
    log "FAIL: /health never became ready"
    ($DOCKER ps || true) | tee -a "$LOG"
    [[ -n "$N8N_CID" ]] && ($DOCKER logs --tail 200 "$N8N_CID" || true) | tee -a "$LOG"
    ($DOCKER logs --tail 200 caddy_reverse_proxy || true) | tee -a "$LOG"
    exit 1
  fi

  log "HEALTHCHECK phase2: жду ответ n8n за прокси на ${HOST_DOMAIN}/ (200/204/401)"
  READY=0
  for i in {1..40}; do
    CODE="$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${HOST_DOMAIN}/")"
    if [[ "$CODE" = "200" || "$CODE" = "204" || "$CODE" = "401" ]]; then
      log "HEALTHCHECK: n8n ready (HTTP $CODE)"
      READY=1
      break
    fi
    log "HEALTHCHECK: n8n not ready yet (HTTP $CODE), try $i/40, wait 5s..."
    sleep 5
  done

  if [[ $READY -ne 1 ]]; then
    log "FAIL: n8n did not become ready in time. Dumping diagnostics..."
    ($DOCKER ps || true) | tee -a "$LOG"
    [[ -n "$N8N_CID" ]] && ($DOCKER logs --tail 200 "$N8N_CID" || true) | tee -a "$LOG"
    ($DOCKER logs --tail 200 caddy_reverse_proxy || true) | tee -a "$LOG"
    exit 1
  fi
else
  log "HEALTHCHECK: пропущен (HOST_DOMAIN не задан или выключен флагом --no-health)"
fi

# --- лёгкая ротация бэкапов (по умолчанию старше $RETAIN_DAYS дней) ---
find "$BACKUP_DIR" -type f -name 'n8n_data_*.tar.gz' -mtime +$RETAIN_DAYS -delete 2>/dev/null || true
find "$BACKUP_DIR" -type f -name 'n8n_image_*.tar.gz' -mtime +$RETAIN_DAYS -delete 2>/dev/null || true

# --- подсказка по FROM в Dockerfile ---
DOCKERFILE_PATH="$(awk -v RS='\0' 'match($0, /dockerfile:[[:space:]]*([^\n]+)/, a){print a[1]}' "$COMPOSE_FILE" || true)"
[[ -z "$DOCKERFILE_PATH" ]] && DOCKERFILE_PATH="$COMPOSE_DIR/Dockerfile"
if [[ -f "$DOCKERFILE_PATH" ]]; then
  FROM_LINE="$(grep -E '^[[:space:]]*FROM[[:space:]]+n8nio/n8n' "$DOCKERFILE_PATH" || true)"
  [[ -n "$FROM_LINE" ]] && log "Dockerfile: $(basename "$DOCKERFILE_PATH") | $FROM_LINE"
  if echo "$FROM_LINE" | grep -qE 'n8nio/n8n:[0-9]'; then
    log "WARNING: В Dockerfile зафиксирован конкретный тег базового образа — обновления будут в рамках этого тега."
  fi
else
  log "WARNING: Dockerfile не найден по пути $DOCKERFILE_PATH"
fi

log "=== FINISH n8n update ==="
