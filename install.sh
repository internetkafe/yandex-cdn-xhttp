#!/bin/bash

if [ "$#" -ne 2 ]; then
    echo "Использование: $0 <домен> <порт_xray>"
    echo "Пример: $0 your.server.com 8185"
    exit 1
fi

DOMAIN=$1
PORT=$2
WEBROOT="/var/www/certbot"

if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
    echo "Ошибка: Порт должен быть числом!"
    exit 1
fi

echo "=================================================="
echo " Установка Nginx + Certbot (Без Rewrite)"
echo " Домен: $DOMAIN | Порт: $PORT"
echo "=================================================="

echo "[1/5] Установка Nginx и Certbot..."
apt update -y
apt install -y nginx certbot

echo "[2/5] Жесткая очистка ВСЕХ старых конфигов Nginx..."
rm -f /etc/nginx/sites-enabled/*
rm -f /etc/nginx/sites-available/*
rm -f /etc/nginx/conf.d/*
mkdir -p $WEBROOT

# Выпуск SSL
if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
    echo "[3/5] Выпуск SSL сертификата..."
    cat <<EOF > /etc/nginx/sites-available/temp_cert
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root $WEBROOT; }
    location / { return 200 'Wait...'; }
}
EOF
    ln -sf /etc/nginx/sites-available/temp_cert /etc/nginx/sites-enabled/temp_cert
    systemctl reload nginx
    certbot certonly --webroot -w $WEBROOT -d $DOMAIN --non-interactive --agree-tos --register-unsafely-without-email
    rm -f /etc/nginx/sites-enabled/temp_cert /etc/nginx/sites-available/temp_cert
else
    echo "[3/5] SSL сертификат уже есть, пропуск..."
fi

# Определение синтаксиса HTTP/2
echo "[4/5] Генерация финального конфига..."
NGINX_VER=$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+')
if awk -v v="$NGINX_VER" 'BEGIN {if (v >= 1.25.1) exit 0; else exit 1}'; then
    HTTP2_CMD="http2 on;"
    LISTEN_CMD="listen 443 ssl;"
    LISTEN_V6="listen [::]:443 ssl;"
else
    HTTP2_CMD=""
    LISTEN_CMD="listen 443 ssl http2;"
    LISTEN_V6="listen [::]:443 ssl http2;"
fi

cat <<EOF > /etc/nginx/sites-available/xhttp_${DOMAIN}
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root $WEBROOT; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    server_name $DOMAIN;

    $LISTEN_CMD
    $LISTEN_V6
    $HTTP2_CMD

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # Прозрачный прокси. Ловит ВСЁ что начинается с /rpc-cdn
    # Не модифицирует URI (Никакого rewrite)
    location /rpc-cdn {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # Для uplinkDataPlacement: "body"
        client_max_body_size 0;
        
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        chunked_transfer_encoding on;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location / {
        return 200 "OK";
        add_header Content-Type text/plain;
    }
}
EOF

ln -sf /etc/nginx/sites-available/xhttp_${DOMAIN} /etc/nginx/sites-enabled/xhttp_${DOMAIN}

echo "[5/5] Проверка и перезапуск..."
if nginx -t; then
    systemctl reload nginx
    echo "=================================================="
    echo ">>> ГОТОВО. Nginx пропускает запросы как есть."
    echo "=================================================="
else
    echo ">>> ОШИБКА КОНФИГУРАЦИИ NGINX!"
fi
