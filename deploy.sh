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

# --add Додавання магазину
# -----------------------------

add_store() {
echo "Розпочинаємо з перевірки компонентів"


# NGINX виклик функцій перевірки
# -----------------------------

echo "=== NGINX ==="
ensure_packages nginx
ensure_service nginx


# MARIADB виклик функцій перевірки
# -----------------------------

echo "=== MariaDB ==="
ensure_packages mariadb-server mariadb-client
ensure_service mariadb


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
echo "Перевірка скелетону"
echo
	[ -d "$SKELETON_DIR" ] || {
  echo "Skeleton not found: $SKELETON_DIR"
  exit 1
}
echo "Перевірка сокету"
echo
[ -S /run/php/php8.3-fpm.sock ] || {
  echo "PHP-FPM socket not found"
  exit 1
}

  read -p "Domain: " DOMAIN
  read -p "Mode (demo/prod): " MODE

  #заміняємо дефіси та крапки в іменах баз даних
  echo "Заміняємо дефіси та крипки..."
  echo
  SAFE_NAME=$(echo "$DOMAIN" | tr '.-' '_' )
  DB_NAME="oc_${SAFE_NAME}"
  DB_USER="oc_${SAFE_NAME}"

  # DB_NAME="oc_${DOMAIN//./_}"
  # DB_USER="$DB_NAME"
  DB_PASS=$(openssl rand -base64 16)
  echo "Пароль DB: "$DB_PASS
  echo
  ROOT="$WWW_DIR/$DOMAIN"

  mkdir -p "$ROOT" "$BASE_DIR/stores"
  echo "Створили теку: " $ROOT ","$BASE_DIR/stores
  echo

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
  echo "Створили config.php #FFFFFF"

# Permissions -перенесено нижче

# Якщо в каталозі магазину ще НЕ існує папка admin,
  # то скопіювати туди весь OpenCart зі skeleton.
  if [ ! -d "$ROOT/admin" ]; then
  cp -a "$SKELETON_DIR/." "$ROOT/"
fi

# Permissions
mkdir -p "$ROOT/storage"
chown -R www-data:www-data "$ROOT"
find "$ROOT" -type d -exec chmod 755 {} \;
find "$ROOT" -type f -exec chmod 644 {} \;

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



ADMIN_PASS=$(openssl rand -base64 12)
echo "Пароль адміна: "$ADMIN_PASS

# прапорець demo (якщо режим demo)
[ "$MODE" = "demo" ] && DEMO_FLAG="--demo-data" || DEMO_FLAG=""



#  $DEMO_FLAG || {
#      echo "OpenCart install failed"
#      exit 1
#    }

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

  # зберігаємо admin пароль
    mkdir -p "$BASE_DIR/data"
    echo "$DOMAIN | admin | $AUTH_USER | $AUTH_PASS" >> "$BASE_DIR/data/credentials.log"
    chmod 600 "$BASE_DIR/data/credentials.log"
  fi

  # Nginx
  TEMPLATE="$BASE_DIR/templates/nginx.$MODE.tpl"
  sed "s/{{DOMAIN}}/$DOMAIN/g" "$TEMPLATE" > "$NGINX_AVAIL/$DOMAIN"
  ln -s "$NGINX_AVAIL/$DOMAIN" "$NGINX_ENABLED/$DOMAIN"
  
  # --- OpenCart 4 CLI install ---
  php "$ROOT/install/cli_install.php" install --username admin --email "admin@$DOMAIN" --password "$ADMIN_PASS" --http_server "https://$DOMAIN/" --language en-gb --db_driver mysqli --db_hostname localhost --db_username "$DB_USER" --db_password "$DB_PASS" --db_database "$DB_NAME" --db_port 3306 --db_prefix oc_

#
#
#
#
#
#
#
echo "cli_install.php Завершено???"

mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" <<EOF
INSERT INTO oc_language
(language_id, name, code, locale, extension, sort_order, status)
VALUES
(2,'Українська', 'uk-ua', 'uk_UA', NULL, 1, 1);
EOF
echo "Українську в базу даних додано"

mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" <<'EOF'
UPDATE oc_setting SET value='uk-ua' WHERE `key`='config_language_catalog';
UPDATE oc_setting SET value='uk-ua' WHERE `key`='config_language_admin';
EOF
echo "Українська за замовчуванням виставлена"


SRC_LANG_ID=1
NEW_LANG_ID=2
DB_PREFIX="oc_"

echo "▶ Клонуємо переклади (oc_translation)"

mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" <<'SQL'
INSERT INTO oc_translation
(store_id, language_id, route, `key`, value)
SELECT
  store_id,
  2,
  route,
  `key`,
  value
FROM oc_translation
WHERE language_id = 1
AND (store_id, route, `key`) NOT IN (
  SELECT store_id, route, `key`
  FROM oc_translation
  WHERE language_id = 2
);
SQL




#---Клонування демо контенту uk
clone_language() {
  echo "======================================"
  echo "▶ Клонуємо demo-контент: language_id $SRC_LANG_ID → $NEW_LANG_ID"
  echo "======================================"

  # 1️⃣ Категорії
  echo "▶ Категорії"
  mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" <<SQL
INSERT INTO ${DB_PREFIX}category_description
(category_id, language_id, name, description, meta_title, meta_description, meta_keyword)
SELECT
  category_id,
  $NEW_LANG_ID,
  name,
  description,
  meta_title,
  meta_description,
  meta_keyword
FROM ${DB_PREFIX}category_description
WHERE language_id = $SRC_LANG_ID
AND category_id NOT IN (
  SELECT category_id FROM ${DB_PREFIX}category_description WHERE language_id = $NEW_LANG_ID
);
SQL

  # 2️⃣ Товари
  echo "▶ Товари"
  mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" <<SQL
INSERT INTO ${DB_PREFIX}product_description
(product_id, language_id, name, description, tag, meta_title, meta_description, meta_keyword)
SELECT
  product_id,
  $NEW_LANG_ID,
  name,
  description,
  tag,
  meta_title,
  meta_description,
  meta_keyword
FROM ${DB_PREFIX}product_description
WHERE language_id = $SRC_LANG_ID
AND product_id NOT IN (
  SELECT product_id FROM ${DB_PREFIX}product_description WHERE language_id = $NEW_LANG_ID
);
SQL

  # 3️⃣ Інформаційні сторінки (About, Delivery, Privacy)
  echo "▶ Інформаційні сторінки"
  mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" <<SQL
INSERT INTO ${DB_PREFIX}information_description
(information_id, language_id, title, description, meta_title, meta_description, meta_keyword)
SELECT
  information_id,
  $NEW_LANG_ID,
  title,
  description,
  meta_title,
  meta_description,
  meta_keyword
FROM ${DB_PREFIX}information_description
WHERE language_id = $SRC_LANG_ID
AND information_id NOT IN (
  SELECT information_id FROM ${DB_PREFIX}information_description WHERE language_id = $NEW_LANG_ID
);
SQL

  # 4️⃣ Статуси замовлень
  echo "▶ Статуси замовлень"
  mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" <<SQL
INSERT INTO ${DB_PREFIX}order_status
(order_status_id, language_id, name)
SELECT
  order_status_id,
  $NEW_LANG_ID,
  name
FROM ${DB_PREFIX}order_status
WHERE language_id = $SRC_LANG_ID
AND order_status_id NOT IN (
  SELECT order_status_id FROM ${DB_PREFIX}order_status WHERE language_id = $NEW_LANG_ID
);
SQL

  # 5️⃣ Наявність на складі
  echo "▶ Статуси наявності"
  mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" <<SQL
INSERT INTO ${DB_PREFIX}stock_status
(stock_status_id, language_id, name)
SELECT
  stock_status_id,
  $NEW_LANG_ID,
  name
FROM ${DB_PREFIX}stock_status
WHERE language_id = $SRC_LANG_ID
AND stock_status_id NOT IN (
  SELECT stock_status_id FROM ${DB_PREFIX}stock_status WHERE language_id = $NEW_LANG_ID
);
SQL

  # 6️⃣ Теми (інколи використовуються)
  echo "▶ Теми"
  mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" <<SQL
INSERT INTO ${DB_PREFIX}theme
(theme_id, store_id, language_id, route, code)
SELECT
  theme_id,
  store_id,
  $NEW_LANG_ID,
  route,
  code
FROM ${DB_PREFIX}theme
WHERE language_id = $SRC_LANG_ID
AND (theme_id, route) NOT IN (
  SELECT theme_id, route FROM ${DB_PREFIX}theme WHERE language_id = $NEW_LANG_ID
);
SQL

  echo "✅ Клонування demo-контенту завершено"
}



rm -rf "$ROOT/system/storage/cache/"*
rm -rf "$ROOT/system/storage/modification/"*
echo "Кеш очищено."

#---ПЕревірка конфігурації nginx та її перезавантаження---
  
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
echo "НЕВидаляємо $ROOT/install !!!"
#rm -rf "$ROOT/install"
  echo "✔ Store added: $DOMAIN"


}

  #---Кінець блоку додавання магазину!---
  
  #--- Видалення магазину
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
