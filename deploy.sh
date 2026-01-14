#!/usr/bin/env bash
set -e

BASE_DIR="/opt/opencart"
WWW_DIR="/var/www"
NGINX_AVAIL="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
SKELETON_DIR="$BASE_DIR/skeleton/upload"

usage() {
  echo "Usage:"
  echo "  --add"
  echo "  --remove DOMAIN"
  echo "  --snapshot DOMAIN"
  echo "  --reset DOMAIN"
  echo "  --reset-all-demo"
  exit 0
}

ensure_root() {
  if [ "$EUID" -ne 0 ]; then
 echo "❌ Запустіть скрипт від root: sudo ./deploy.sh"
 exit 1
 fi
}
ensure_mariadb() {
    if ! command -v mysql >/dev/null 2>&1; then
        echo "⚠️  mysql client не знайдено"
        echo "➡️  Встановлюю MariaDB..."

        apt update
        apt install -y mariadb-server mariadb-client
    fi

    if ! systemctl is-active --quiet mariadb; then
        echo "⚠️  MariaDB не запущена"
        echo "➡️  Запускаю mariadb..."

        systemctl start mariadb
        systemctl enable mariadb
    fi

    echo "✅ MariaDB готова"
}
ensure_nginx() {
    if ! command -v nginx >/dev/null 2>&1; then
        echo "⚠️  nginx не знайдено"
        echo "➡️  Встановлюю nginx..."

        apt update
        apt install -y nginx
    fi

    if ! systemctl is-active --quiet nginx; then
        echo "⚠️  nginx не запущений"
        echo "➡️  Запускаю nginx..."

        systemctl start nginx
        systemctl enable nginx
    fi

    echo "✅ nginx готовий"
}

  # Виклик функцій перевірки готовності системи до створення бази даних
ensure_root
ensure_mariadb
ensure_nginx

add_store() {
  read -p "Domain: " DOMAIN
  read -p "Mode (demo/prod): " MODE
  #заміняємо дефіси та крапки в іменах баз даних
  SAFE_NAME=$(echo "$DOMAIN" | tr '.-' '_' )
  DB_NAME="oc_${SAFE_NAME}"
  DB_USER="oc_${SAFE_NAME}"

  # DB_NAME="oc_${DOMAIN//./_}"
  # DB_USER="$DB_NAME"
  DB_PASS=$(openssl rand -base64 16)
  ROOT="$WWW_DIR/$DOMAIN"

  mkdir -p "$ROOT" "$BASE_DIR/stores"
  # Додатно для створення теки скелетону
  if [ ! -d "$ROOT/admin" ]; then
  cp -a "$SKELETON_DIR/." "$ROOT/"
fi
# Generate OpenCart config.php
cat > "$ROOT/config.php" <<EOF
<?php
define('HTTP_SERVER', 'https://$DOMAIN/');
define('HTTPS_SERVER', 'https://$DOMAIN/');

define('DIR_APPLICATION', '$ROOT/catalog/');
define('DIR_SYSTEM', '$ROOT/system/');
define('DIR_IMAGE', '$ROOT/image/');
define('DIR_STORAGE', '$ROOT/storage/');
define('DIR_LANGUAGE', '$ROOT/catalog/language/');
define('DIR_TEMPLATE', '$ROOT/catalog/view/theme/');
define('DIR_CONFIG', '$ROOT/system/config/');
define('DIR_CACHE', '$ROOT/system/storage/cache/');
define('DIR_DOWNLOAD', '$ROOT/system/storage/download/');
define('DIR_LOGS', '$ROOT/system/storage/logs/');
define('DIR_MODIFICATION', '$ROOT/system/storage/modification/');
define('DIR_UPLOAD', '$ROOT/system/storage/upload/');

define('DB_DRIVER', 'mysqli');
define('DB_HOSTNAME', 'localhost');
define('DB_USERNAME', '$DB_USER');
define('DB_PASSWORD', '$DB_PASS');
define('DB_DATABASE', '$DB_NAME');
define('DB_PORT', '3306');
define('DB_PREFIX', 'oc_');
EOF

# Generate admin config.php
cat > "$ROOT/admin/config.php" <<EOF
<?php
define('HTTP_SERVER', 'https://$DOMAIN/admin/');
define('HTTPS_SERVER', 'https://$DOMAIN/admin/');

define('DIR_APPLICATION', '$ROOT/admin/');
define('DIR_SYSTEM', '$ROOT/system/');
define('DIR_IMAGE', '$ROOT/image/');
define('DIR_STORAGE', '$ROOT/storage/');
define('DIR_LANGUAGE', '$ROOT/admin/language/');
define('DIR_TEMPLATE', '$ROOT/admin/view/template/');
define('DIR_CATALOG', '$ROOT/catalog/');
define('DIR_LOGS', '$ROOT/system/storage/logs/');
define('DIR_MODIFICATION', '$ROOT/system/storage/modification/');
define('DIR_UPLOAD', '$ROOT/system/storage/upload/');

define('DB_DRIVER', 'mysqli');
define('DB_HOSTNAME', 'localhost');
define('DB_USERNAME', '$DB_USER');
define('DB_PASSWORD', '$DB_PASS');
define('DB_DATABASE', '$DB_NAME');
define('DB_PORT', '3306');
define('DB_PREFIX', 'oc_');
EOF
# Permissions
mkdir -p "$ROOT/storage"
chown -R www-data:www-data "$ROOT"
find "$ROOT" -type d -exec chmod 755 {} \;
find "$ROOT" -type f -exec chmod 644 {} \;


  # DB
  mysql <<EOF
CREATE DATABASE $DB_NAME;
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

  # ENV
  cat > "$BASE_DIR/stores/$DOMAIN.env" <<EOF
DOMAIN=$DOMAIN
MODE=$MODE
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASS=$DB_PASS
ROOT=$ROOT
EOF

  # Basic Auth (demo only)
  if [ "$MODE" = "demo" ]; then
    AUTH_USER=demo
    AUTH_PASS=$(openssl rand -base64 12)
    HTP="/etc/nginx/.htpasswd_$DOMAIN"

    printf "%s:%s\n" "$AUTH_USER" "$(openssl passwd -apr1 $AUTH_PASS)" > "$HTP"

    mkdir -p "$BASE_DIR/data"
    echo "$DOMAIN | admin | $AUTH_USER | $AUTH_PASS" >> "$BASE_DIR/data/credentials.log"
    chmod 600 "$BASE_DIR/data/credentials.log"
  fi

  # Nginx
  TEMPLATE="$BASE_DIR/templates/nginx.$MODE.tpl"
  sed "s/{{DOMAIN}}/$DOMAIN/g" "$TEMPLATE" > "$NGINX_AVAIL/$DOMAIN"
  ln -s "$NGINX_AVAIL/$DOMAIN" "$NGINX_ENABLED/$DOMAIN"

  nginx -t && systemctl reload nginx

  echo "✔ Store added: $DOMAIN"
}

remove_store() {
  DOMAIN="$1"
  source "$BASE_DIR/stores/$DOMAIN.env"

  mysql -e "DROP DATABASE $DB_NAME; DROP USER '$DB_USER'@'localhost';"
  rm -rf "$ROOT"
  rm -f "$NGINX_AVAIL/$DOMAIN" "$NGINX_ENABLED/$DOMAIN"
  rm -f "/etc/nginx/.htpasswd_$DOMAIN"
  rm -f "$BASE_DIR/stores/$DOMAIN.env"
  rm -rf "$BASE_DIR/snapshots/$DOMAIN"

  nginx -t && systemctl reload nginx
  echo "✖ Removed $DOMAIN"
}

snapshot_store() {
  DOMAIN="$1"
  source "$BASE_DIR/stores/$DOMAIN.env"

  [ "$MODE" != "demo" ] && echo "Snapshot only for demo" && exit 1

  mkdir -p "$BASE_DIR/snapshots/$DOMAIN"
  mysqldump "$DB_NAME" | gzip > "$BASE_DIR/snapshots/$DOMAIN/db.sql.gz"
  tar czf "$BASE_DIR/snapshots/$DOMAIN/files.tar.gz" -C "$ROOT" .

  echo "📦 Snapshot created for $DOMAIN"
}

reset_demo() {
  DOMAIN="$1"
  source "$BASE_DIR/stores/$DOMAIN.env"

  [ "$MODE" != "demo" ] && exit 0

  mysql -e "DROP DATABASE $DB_NAME; CREATE DATABASE $DB_NAME;"
  gunzip < "$BASE_DIR/snapshots/$DOMAIN/db.sql.gz" | mysql "$DB_NAME"

  rm -rf "$ROOT"/*
  tar xzf "$BASE_DIR/snapshots/$DOMAIN/files.tar.gz" -C "$ROOT"
  chown -R www-data:www-data "$ROOT"

  echo "🔄 Reset demo: $DOMAIN"
}

reset_all_demo() {
  for ENV in "$BASE_DIR/stores/"*.env; do
    source "$ENV"
    [ "$MODE" = "demo" ] && reset_demo "$DOMAIN"
  done
}

ensure_root

case "$1" in
  --add) add_store ;;
  --remove) remove_store "$2" ;;
  --snapshot) snapshot_store "$2" ;;
  --reset) reset_demo "$2" ;;
  --reset-all-demo) reset_all_demo ;;
  *) usage ;;
esac
