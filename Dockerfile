FROM n8nio/n8n:latest

USER root

# Устанавливаем Python 3, pip и нужные библиотеки
RUN apk add --no-cache postgresql-client
USER node
