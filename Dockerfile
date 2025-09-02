FROM docker.n8n.io/n8nio/n8n:1.102.0

USER root

# Устанавливаем Python 3, pip и нужные библиотеки
RUN apk add --no-cache python3 py3-pip postgresql-client && \
    pip3 install --no-cache-dir requests pandas pymysql --break-system-packages && \
    ln -sf /usr/bin/python3 /usr/bin/python

USER node