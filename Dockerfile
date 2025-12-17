ARG N8N_TAG=1.123.6
FROM n8nio/n8n:${N8N_TAG}

USER root

# Устанавливаем Python 3, pip и нужные библиотеки
RUN apk add --no-cache postgresql-client
USER node
