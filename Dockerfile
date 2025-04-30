FROM n8nio/n8n:latest

USER root

# Устанавливаем Python 3, pip и нужные библиотеки через apk
RUN apk add --no-cache python3 py3-pip && \
    pip3 install --no-cache-dir requests pandas && \
    ln -sf /usr/bin/python3 /usr/bin/python

USER node