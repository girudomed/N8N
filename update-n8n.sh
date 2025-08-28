#!/bin/bash
set -Eeuo pipefail

# === базовые настройки (переопределяемы переменными окружения) ===
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

LOG="${LOG:-/var/log/n8n-nightly-update.log}"
COMPOSE_DIR="${COMPOSE_DIR:-/root/N8N}"                 # каталог с docker-compose.yml
COMPOSE_FILE="${COMPOSE_FILE:-$COMPOSE_DIR/docker-compose.yml}"
DATA_DIR="${DATA_DIR:-/root/n8n_data}"                  # том с данными n8n
BACKUP_DIR="${BACKUP_DIR:-/root/n8n_backups}"
LOCK_FILE="${LOCK_FILE:-$DATA_DIR/update.lock}"
IMAGE_REPO="${IMAGE_REPO:-n8nio/n8n:latest}"            # базовый образ в Dockerfile
RETAIN_DAYS="${RETAIN_DAYS:-30}"                        # хранить бэкапы N дней

# флаги
RUN_FROM_CRON=0
SKIP_BACKUP=0
FORCE=0

usage() {
  cat <<'USAGE'
Usage: nightly-update-n8n.sh [--cron] [--skip-backup] [--force] [--compose-dir PATH] [--compose-file FILE]
  --cron          помечает запуск из cron (для логов)
  --skip-backup   пропустить архивирование DATA_DIR
  --force         игнорировать существующий lock-файл
  --compose-dir   путь к каталогу с docker-compose.yml (по умолчанию /root/N8N)
  --compose-file  явный путь к docker-compose.yml
env:
  LOG, COMPOSE_DIR, COMPOSE_FILE, DATA_DIR, BACKUP_DIR, LOCK_FILE, IMAGE_REPO, RETAIN_DAYS — можно задать через окружение
USAGE
}

# --- разбор аргументов ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cron) RUN_FROM_CRON=1; shift ;;
    --skip-backup) SKIP_BACKUP=1; shift ;;
    --force) FORCE=1; shift ;;
    --compose-dir) COMPOSE_DIR="$2"; COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"; shift 2 ;;
    --compose-file) COMPOSE_FILE="$2"; COMPOSE_DIR="$(dirname "$2")"; shift 2 ;;
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
log "compose_file=$COMPOSE_FILE | data_dir=$DATA_DIR | backup_dir=$BACKUP_DIR | image_repo=$IMAGE_REPO"

# --- блокировка ---
if [[ -e "$LOCK_FILE" && $FORCE -eq 0 ]]; then
  log "Lock $LOCK_FILE существует — выходим (используй --force, если уверен)"
  exit 1
fi
mkdir -p "$(dirname "$LOCK_FILE")"
: > "$LOCK_FILE"
trap 'rc=$?; rm -f "$LOCK_FILE"; log "Lock удалён. Выход с кодом $rc"; exit $rc' EXIT

# --- бэкап данных ---
if [[ $SKIP_BACKUP -eq 0 ]]; then
  if [[ -d "$DATA_DIR" ]]; then
    ARCHIVE="$BACKUP_DIR/n8n_data_$(date +'%F_%H%M%S').tar.gz"
    log "Создаю бэкап $DATA_DIR -> $ARCHIVE"
    if ! tar -C "$(dirname "$DATA_DIR")" -czf "$ARCHIVE" "$(basename "$DATA_DIR")" >>"$LOG" 2>&1; then
      log "WARNING: бэкап данных не удался — продолжу (данные НЕ трогаю)"
    fi
  else
    log "WARNING: $DATA_DIR не найден — бэкап пропущен"
  fi
else
  log "Бэкап пропущен по флагу --skip-backup"
fi

# --- резерв текущего образа контейнера (для отката) ---
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

# --- подтягиваем свежий базовый образ, чтобы Dockerfile пересобрался на свежей базе ---
log "docker pull $IMAGE_REPO"
if ! $DOCKER pull "$IMAGE_REPO" >>"$LOG" 2>&1; then
  log "ERROR: docker pull $IMAGE_REPO не удался"; exit 1
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