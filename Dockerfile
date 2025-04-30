FROM n8nio/n8n:latest

USER root

# Устанавливаем Python, pip и нужные библиотеки
RUN apt-get update && \
    apt-get install -y python3 python3-pip && \
    pip3 install --no-cache-dir requests pandas && \
    ln -s /usr/bin/python3 /usr/bin/python

USER node