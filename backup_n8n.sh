#!/bin/bash
set -Eeuo pipefail

### ===== Настройки =====
LOG="/var/log/backup_n8n.log"
LOCKFILE="/var/lock/backup_n8n.lock"

# Где копим бэкапы
BACKUP_DIR="/root/n8n_backups"

# Где лежат файлы n8n (заберём encryptionKey из config)
N8N_DATA_DIR="/root/n8n_data"
N8N_CONFIG_FILE="$N8N_DATA_DIR/config"   # JSON с "encryptionKey"

# Имя контейнера с Postgres
PG_CONTAINER="n8n-postgres-1"

# Сколько архивов держать
RETENTION_PG=7

# Минимальный запас свободного места перед стартом (байт)
MIN_FREE=$(( 500 * 1024 * 1024 ))  # 500 MiB

PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
DOCKER_BIN="$(command -v docker || true)"

ts()  { date +'%F %T'; }
log() { echo "[$(ts)] $*" | tee -a "$LOG" >/dev/null; }

### ===== Подготовка =====
mkdir -p "$(dirname "$LOG")" "$BACKUP_DIR"
touch "$LOG" && chmod 0644 "$LOG" || { echo "cannot write $LOG" >&2; exit 1; }

# Эксклюзивный запуск
exec 9>"$LOCKFILE"
if ! flock -n 9; then log "Another backup is running. Exit."; exit 0; fi

# грузим переменные из .env (если есть)
ENV_FILE="/root/N8N/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # важно: .env у тебя валидный для bash (KEY=VALUE, могут быть ссылки ${...})
  # не логируем содержимое!
  . "$ENV_FILE"
  set +a
fi

# выбираем креды: сперва DB_POSTGRESDB_*, затем POSTGRES_*, иначе дефолты
PGUSER="${DB_POSTGRESDB_USER:-${POSTGRES_USER:-n8n}}"
PGPASSWORD="${DB_POSTGRESDB_PASSWORD:-${POSTGRES_PASSWORD:-}}"
PGDATABASE="${DB_POSTGRESDB_DATABASE:-${POSTGRES_DB:-n8n}}"

# будем коннектиться по unix-сокету внутри контейнера — host/port не нужны
[[ -n "$DOCKER_BIN" ]]   || { log "ERROR: docker not found"; exit 1; }
[[ -n "$PGPASSWORD" ]]   || { log "ERROR: Postgres password is empty"; exit 1; }