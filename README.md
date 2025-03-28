🚀 N8N Production Deploy — Timeweb Cloud

Автодеплой + Docker + Nginx + HTTPS

⸻

📁 Структура проекта

N8N/
│
├── .github/
│   └── deploy.yml                 # CI/CD скрипт для автоматического деплоя через GitHub Actions
│
├── conf.d/
│   └── n8n.conf                   # Основной конфиг для Nginx (проксирование, HTTPS)
│
├── .dockerignore                  # Файл исключений для Docker
├── docker-compose.yml             # Основной Docker Compose для n8n и nginx
├── nginx.conf                     # Глобальная конфигурация nginx
└── README.md                      # Это описание проекта



⸻

✅ Что здесь происходит
	1.	N8N запускается в Docker-контейнере
	•	Порт по умолчанию: 5678
	•	Проброшен в docker-compose: 5678:5678
	•	Используется базовая HTTP-авторизация.
	2.	Nginx работает как реверс-прокси
	•	Слушает 80/443 порты.
	•	Перенаправляет весь трафик на контейнер n8n.
	•	Отдает HTTPS-сертификаты из /etc/letsencrypt.
	3.	Автодеплой из GitHub
	•	При пуше в ветку main автоматически:
	•	Подключается по SSH к серверу.
	•	Клонирует или обновляет репозиторий.
	•	Перезапускает контейнеры.
	•	Валидирует конфигурацию nginx.
	•	Проверяет доступность https://n8n.portalgm.ru.
	•	Показывает статус контейнеров.

⸻

⚙ Основные файлы:

👉 nginx.conf

Глобальная конфигурация nginx:

	•	Управление воркерами и буферами.
	•	Настройки gzip и логов.
	•	Подключение всех конфигов из conf.d/.

⸻

👉 conf.d/n8n.conf

Конфиг для твоего домена n8n.portalgm.ru:

	•	Редирект с http → https.
	•	SSL-сертификаты.
	•	Проксирование на n8n:5678.
	•	Заголовки для корректной передачи авторизации.
	•	Обработка отсутствующих файлов (favicon, robots.txt).
	•	Готовые буферы для крупных ответов.
	•	Возможность заблокировать ботов (раскомментируешь при желании).

⸻

👉 docker-compose.yml

Два контейнера:

	•	n8n с переменными окружения (SMTP, Webhook, BasicAuth и прочее).
	•	nginx с пробросом конфигов и SSL-сертификатов.

⸻

👉 .github/deploy.yml

GitHub Actions CI/CD:

	•	Обновляет код на сервере.
	•	Пересобирает контейнеры.
	•	Валидирует nginx конфиг.
	•	Перезапускает nginx.
	•	Проверяет доступность сайта.
	•	Выводит список работающих контейнеров.

⸻

🔑 Переменные и настройки n8n:
	•	N8N_BASIC_AUTH_ACTIVE=true — активируем базовую авторизацию.
	•	N8N_BASIC_AUTH_USER=admin — логин.
	•	N8N_BASIC_AUTH_PASSWORD=... — пароль.
	•	SMTP-конфигурация для отправки писем.
	•	WEBHOOK_URL=https://n8n.portalgm.ru/
	•	N8N_RUNNERS_ENABLED=true — актуально для последних версий n8n.

⸻

📡 Как развернуть с нуля:

git clone https://github.com/ТВОЙ-РЕПО.git ~/N8N
cd ~/N8N
docker-compose up --build -d

Проверка nginx:

docker exec n8n_nginx_1 nginx -t
docker restart n8n_nginx_1

Проверка доступности:

curl -I https://n8n.portalgm.ru



⸻

👀 Полезные команды:
	•	Логи:

docker logs -f n8n_n8n_1
docker logs -f n8n_nginx_1


	•	Список всех контейнеров:

docker ps -a


	•	Перезапуск:

docker-compose down -v
docker-compose up -d --build


	•	Проверка HTTPS-сертификатов:

openssl x509 -in /etc/letsencrypt/live/n8n.portalgm.ru/fullchain.pem -noout -dates


	•	Очистка Docker:

docker system prune -a



⸻

🌟 Если что-то пошло не так:
	•	Проверяй:

docker logs -f n8n_nginx_1
docker exec n8n_nginx_1 nginx -t


	•	Перезапусти nginx:

docker restart n8n_nginx_1


	•	Удостоверся, что SSL свежий:

sudo certbot renew --nginx

