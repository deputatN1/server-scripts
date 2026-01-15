#!/usr/bin/env bash
set -e

BASE_DIR="/opt/opencart"
WWW_DIR="/var/www"
NGINX_AVAIL="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
SKELETON_DIR="$BASE_DIR/skeleton/upload"
PHP_VER="8.3"

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

ensure_root

# -----------------------------
# Утилітарні функції
# -----------------------------

ensure_packages() {
    local packages=("$@")
    local missing=()

    for pkg in "${packages[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "➡️  Встановлюю пакети:"
        printf '  - %s\n' "${missing[@]}"
        apt update
        apt install -y "${missing[@]}"
    else
        echo "✅ Усі пакети вже встановлені"
    fi
}

ensure_service() {
    local service="$1"

    if ! systemctl is-active --quiet "$service"; then
        echo "➡️  Запускаю $service"
        systemctl start "$service"
    fi

    systemctl enable "$service" >/dev/null 2>&1
}

# -----------------------------
# --add Додавання магазину
# -----------------------------

add_store() {
echo "Розпочинаємо з перевірки компонентів"

# -----------------------------
# NGINX
# -----------------------------

echo "=== NGINX ==="
ensure_packages nginx
ensure_service nginx

# -----------------------------
# MARIADB
# -----------------------------

echo "=== MariaDB ==="
ensure_packages mariadb-server mariadb-client
ensure_service mariadb

# -----------------------------
# PHP
# -----------------------------

echo "=== PHP ${PHP_VER} ==="

PHP_PACKAGES=(
    php${PHP_VER}-fpm
    php${PHP_VER}-mysql
    php${PHP_VER}-curl
    php${PHP_VER}-gd
    php${PHP_VER}-intl
    php${PHP_VER}-mbstring
    php${PHP_VER}-xml
    php${PHP_VER}-zip
    php${PHP_VER}-soap
)

ensure_packages "${PHP_PACKAGES[@]}"
ensure_service php${PHP_VER}-fpm

# -----------------------------
# Перевірки
# -----------------------------

echo
echo "=== Перевірка версій програм==="

nginx -v
php -v | head -n1
mysql --version

echo
echo "✅ Nginx + MariaDB + PHP ${PHP_VER} готові до роботи"
echo
echo "Перевірка наявності скелетону"	
	[ -d "$SKELETON_DIR" ] || {
  echo "Skeleton not found: $SKELETON_DIR"
  exit 1
}
echo "Перевірка наявності сокету"
[ -S /run/php/php8.3-fpm.sock ] || {
  echo "PHP-FPM socket not found"
  exit 1
}

  read -p "Domain: " DOMAIN
  read -p "Mode (demo/prod): " MODE
  
  #заміняємо дефіси та крапки в іменах баз даних
  echo "Заміняємо дефіси та крипки в іменах"
  SAFE_NAME=$(echo "$DOMAIN" | tr '.-' '_' )
  DB_NAME="oc_${SAFE_NAME}"
  DB_USER="oc_${SAFE_NAME}"

  # DB_NAME="oc_${DOMAIN//./_}"
  # DB_USER="$DB_NAME"
  DB_PASS=$(openssl rand -base64 16)
  echo "Пароль DB: "$DB_PASS
  ROOT="$WWW_DIR/$DOMAIN"

  mkdir -p "$ROOT" "$BASE_DIR/stores"
  echo "Створили теку: " $ROOT ","$BASE_DIR/stores
  

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
  echo "Створили config.php 180 "
  


# Permissions
mkdir -p "$ROOT/storage"
chown -R www-data:www-data "$ROOT"
find "$ROOT" -type d -exec chmod 755 {} \;
find "$ROOT" -type f -exec chmod 644 {} \;

# Якщо в каталозі магазину ще НЕ існує папка admin,
  # то скопіювати туди весь OpenCart зі skeleton.
  if [ ! -d "$ROOT/admin" ]; then
  cp -a "$SKELETON_DIR/." "$ROOT/"
  
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
echo "Створили admin/config.php "

# --- OpenCart 4 CLI install ---

ADMIN_PASS=$(openssl rand -base64 12)
echo "Пароль адміна: "$ADMIN_PASS

# прапорець demo (якщо режим demo)
[ "$MODE" = "demo" ] && DEMO_FLAG="--demo-data" || DEMO_FLAG=""

php "$ROOT/install/cli_install.php" install \
  --db-host=localhost \
  --db-user="$DB_USER" \
  --db-pass="$DB_PASS" \
  --db-name="$DB_NAME" \
  --db-port=3306 \
  --username=admin \
  --password="$ADMIN_PASS" \
  --email="admin@$DOMAIN" \
  --firstname=Admin \
  --lastname=User \
  --http-server="https://$DOMAIN/" \
  $DEMO_FLAG
  
fi

# зберігаємо admin пароль
echo "$DOMAIN | opencart | admin | $ADMIN_PASS" >> "$BASE_DIR/data/credentials.log"
chmod 600 "$BASE_DIR/data/credentials.log"

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
  
  #---ПЕревірка конфігурації та її перезавантаження---
  if nginx -t; then
    nginx -s reload
    echo "✅ nginx успішно перезавантажено"
else
    echo "❌ Помилка в конфігурації nginx"
fi

# Попередня Перевірка успішності встановлення
echo "Перевірка успішності встановлення"
php "$ROOT/install/cli_install.php" install ... || {
  echo "OpenCart install failed"
  exit 1
}


# після інсталяції install обовʼязково видаляємо
echo "Видаляємо $ROOT/install !!!"
rm -rf "$ROOT/install"
  echo "✔ Store added: $DOMAIN"
  
  #---Кінець блоку додавання магазину!---
}

remove_store() {
	
	[ -z "$1" ] && {
  echo "Domain required! Потрібно вказати домен!"
  exit 1
}

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

case "$1" in
  --add) add_store ;;
  --remove) remove_store "$2" ;;
  --snapshot) snapshot_store "$2" ;;
  --reset) reset_demo "$2" ;;
  --reset-all-demo) reset_all_demo ;;
  *) usage ;;
esac
