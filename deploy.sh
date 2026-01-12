#!/bin/bash
set -e

BASE_DIR="/opt/opencart"
WWW_DIR="/var/www"
NGINX_AVAIL="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"

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
 echo "Потребує root(sudo) "
 exit 1
 fi
}

add_store() {
  read -p "Domain: " DOMAIN
  read -p "Mode (demo/prod): " MODE

  DB_NAME="oc_${DOMAIN//./_}"
  DB_USER="$DB_NAME"
  DB_PASS=$(openssl rand -base64 16)
  ROOT="$WWW_DIR/$DOMAIN"

  mkdir -p "$ROOT" "$BASE_DIR/stores"

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
