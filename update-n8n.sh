#!/bin/bash

set -e

LOCK_FILE="/root/n8n_data/update.lock"
CRON_MARKER="# N8N Monthly Auto-Update"
CRON_ENTRY="5 3 1 * * /root/N8N/nightly-update-n8n.sh >> /var/log/n8n-nightly-update.log 2>&1"

# 🧠 Проверяем наличие cron-записи, добавляем если её нет
if ! crontab -l | grep -qF "$CRON_MARKER"; then
  echo "🛠️ Добавляем автообновление в crontab..."
  (crontab -l 2>/dev/null; echo "$CRON_MARKER"; echo "$CRON_ENTRY") | crontab -
fi

# 🕒 Проверка, что сейчас 03 час
CURRENT_HOUR=$(date +%H)
if [ "$CURRENT_HOUR" -ne 03 ]; then
  echo "⏰ Сейчас не 3 часа ночи. Обновление пропущено."
  exit 0
fi

# 🔒 Проверка блокировки
if [ -f "$LOCK_FILE" ]; then
  echo "🛑 Обнаружен update.lock. Обновление отменено."
  exit 1
fi

echo "📦 Обновляем образ n8n..."
docker pull n8nio/n8n:latest || { echo "❌ Не удалось скачать образ"; exit 1; }

echo "🧹 Останавливаем текущие контейнеры..."
docker-compose down || { echo "❌ Не удалось остановить контейнеры"; exit 1; }

echo "🔨 Пересобираем Dockerfile..."
docker-compose build || { echo "❌ Ошибка при сборке"; exit 1; }

echo "🚀 Запускаем обновлённые контейнеры..."
docker-compose up -d || { echo "❌ Не удалось запустить"; exit 1; }

echo "✅ Обновление завершено. Версия:"
docker exec -it n8n_n8n_1 n8n --version