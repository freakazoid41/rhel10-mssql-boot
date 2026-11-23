#!/usr/bin/env bash
# TedarikApp — RHEL 10 bootstrap (nginx + php-fpm 8.3 + PostgreSQL 16 + app)
# Repo bundle: https://github.com/freakazoid41/rhel10-mssql-boot
#
# Required env:
#   APP_KEY   = copy EXACTLY from the old server .env (do NOT regenerate, SAP creds depend on it)
#   DB_PASS   = password for the postgres app user
# Optional env:
#   GH_TOKEN  = fine-grained token with read access to TalkDigit/tedarik.admelektrik.com.tr
#   DB_NAME   = tedarik      DB_USER = tedarik
#   DOMAIN    = malzemetedarik.gdzelektrik.com.tr
#   APP_DIR   = /var/www/tedarik
#   REPO_URL  = https://github.com/TalkDigit/tedarik.admelektrik.com.tr.git
set -euo pipefail

APP_KEY="${APP_KEY:?export APP_KEY='base64:...' from old .env}"
DB_PASS="${DB_PASS:?export DB_PASS='...'}"
DB_NAME="${DB_NAME:-tedarik}"
DB_USER="${DB_USER:-tedarik}"
DOMAIN="${DOMAIN:-malzemetedarik.gdzelektrik.com.tr}"
APP_DIR="${APP_DIR:-/var/www/tedarik}"
REPO_URL="${REPO_URL:-https://github.com/TalkDigit/tedarik.admelektrik.com.tr.git}"
GH_TOKEN="${GH_TOKEN:-}"

log(){ echo -e "\n\033[1;36m==> $*\033[0m"; }

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)"; exit 1; }

log "timezone + hostname"
timedatectl set-timezone Europe/Istanbul || true

log "base repos sanity"
dnf -C repolist | grep -E 'appstream|baseos' >/dev/null || { echo "EUS repos missing"; exit 1; }

log "base packages (EUS AppStream/BaseOS)"
dnf install -y nginx postgresql-server postgresql-contrib \
  gcc gcc-c++ make git unzip tar rsync policycoreutils-python-utils \
  pkgconf-pkg-config unixODBC
dnf install -y php php-cli php-fpm php-common php-pdo php-pgsql php-mbstring \
  php-xml php-gd php-pecl-zip php-intl php-bcmath php-opcache php-soap \
  php-process php-odbc php-devel php-pear

log "nginx + php-fpm"
systemctl enable --now nginx
sed -i 's/^user = .*/user = nginx/; s/^group = .*/group = nginx/' /etc/php-fpm.d/www.conf
sed -i 's/^listen.owner = .*/listen.owner = nginx/; s/^listen.group = .*/listen.group = nginx/' /etc/php-fpm.d/www.conf
sed -i 's/^listen = .*/listen = \/run\/php-fpm\/www.sock/' /etc/php-fpm.d/www.conf
sed -i 's/^;*listen.mode = .*/listen.mode = 0660/' /etc/php-fpm.d/www.conf
systemctl enable --now php-fpm
php-fpm -t

log "php limits (42MB uploads, xlsx/pdf)"
cat > /etc/php.d/99-tedarik.ini <<'EOF'
memory_limit = 512M
upload_max_filesize = 64M
post_max_size = 70M
max_execution_time = 300
max_input_time = 300
max_input_vars = 10000
date.timezone = Europe/Istanbul
opcache.enable = 1
opcache.memory_consumption = 256
opcache.max_accelerated_files = 20000
opcache.validate_timestamps = 0
EOF
systemctl restart php-fpm

log "PostgreSQL 16"
if [ ! -f /var/lib/pgsql/data/PG_VERSION ]; then
  postgresql-setup --initdb
fi
systemctl enable --now postgresql
sed -i "s/^#\?listen_addresses.*/listen_addresses = 'localhost'/" /var/lib/pgsql/data/postgresql.conf
sed -i 's|^host\s\+all\s\+all\s\+127.0.0.1/32.*|host all all 127.0.0.1/32 scram-sha-256|' /var/lib/pgsql/data/pg_hba.conf
systemctl restart postgresql

log "database + role"
sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 \
  || sudo -u postgres psql -c "CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}';"
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 \
  || sudo -u postgres createdb -O "${DB_USER}" "${DB_NAME}"
sudo -u postgres psql -c "ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASS}';"

log "composer"
curl -fsSL https://getcomposer.org/composer-stable.phar -o /usr/local/bin/composer
chmod +x /usr/local/bin/composer
composer -V

log "clone app -> ${APP_DIR}"
mkdir -p "$(dirname "$APP_DIR")"
if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" fetch --all && git -C "$APP_DIR" reset --hard origin/main
else
  if [ -n "$GH_TOKEN" ]; then
    git clone "https://x-access-token:${GH_TOKEN}@github.com/TalkDigit/tedarik.admelektrik.com.tr.git" "$APP_DIR"
  else
    git clone "$REPO_URL" "$APP_DIR"
  fi
fi

log "composer install (no dev)"
cd "$APP_DIR"
composer install --no-dev --prefer-dist --optimize-autoloader --no-interaction

log ".env"
if [ ! -f .env ]; then
  cp .env.example .env 2>/dev/null || touch .env
fi
python3 - "$APP_KEY" "$DB_NAME" "$DB_USER" "$DB_PASS" "$DOMAIN" <<'PY'
import sys, re, pathlib
key, dbn, dbu, dbp, dom = sys.argv[1:6]
p = pathlib.Path('.env'); txt = p.read_text() if p.exists() else ''
vals = {
 'APP_NAME': '"Tedarik"','APP_ENV':'production','APP_KEY':key,'APP_DEBUG':'false',
 'APP_URL':f'https://{dom}','LOG_LEVEL':'warning',
 'DB_CONNECTION':'pgsql','DB_HOST':'127.0.0.1','DB_PORT':'5432',
 'DB_DATABASE':dbn,'DB_USERNAME':dbu,'DB_PASSWORD':f'"{dbp}"',
 'SESSION_DRIVER':'file','SESSION_LIFETIME':'480','QUEUE_CONNECTION':'sync',
 'CACHE_DRIVER':'file','FILESYSTEM_DISK':'public',
}
lines = txt.splitlines(); seen=set(); out=[]
for ln in lines:
    m = re.match(r'^([A-Z0-9_]+)=', ln)
    if m and m.group(1) in vals:
        out.append(f'{m.group(1)}={vals[m.group(1)]}'); seen.add(m.group(1))
    else:
        out.append(ln)
for k,v in vals.items():
    if k not in seen: out.append(f'{k}={v}')
p.write_text('\n'.join(out).strip()+'\n')
print('written .env')
PY

log "permissions + SELinux"
chown -R nginx:nginx "$APP_DIR"
chmod -R 775 "$APP_DIR/storage" "$APP_DIR/bootstrap/cache"
chcon -Rt httpd_sys_rw_content_t "$APP_DIR/storage" "$APP_DIR/bootstrap/cache"
chcon -Rt httpd_sys_content_t "$APP_DIR/public"
setsebool -P httpd_can_network_connect 1 || true
setsebool -P httpd_can_network_connect_db 1 || true
setsebool -P httpd_can_sendmail 1 || true

log "nginx vhost"
cat > /etc/nginx/conf.d/tedarik.conf <<NGINX
server {
    listen 80;
    server_name ${DOMAIN};
    root ${APP_DIR}/public;
    index index.php;
    client_max_body_size 70M;

    location / { try_files \$uri \$uri/ /index.php?\$query_string; }

    location ~ \.php\$ {
        fastcgi_pass unix:/run/php-fpm/www.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 300;
    }

    location ~ /\.(?!well-known).* { deny all; }
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff2?)\$ { expires 30d; access_log off; }
}
NGINX
nginx -t && systemctl reload nginx

log "firewall"
firewall-cmd --permanent --add-service=http --permanent --add-service=https >/dev/null 2>&1 || true
firewall-cmd --reload >/dev/null 2>&1 || true

log "cron + logrotate"
crontab -u nginx -l 2>/dev/null | grep -q 'schedule:run' || \
  (crontab -u nginx -l 2>/dev/null; echo '* * * * * cd '"$APP_DIR"' && /usr/bin/php artisan schedule:run >> /var/log/tedarik-cron.log 2>&1') | crontab -u nginx -
cat > /etc/logrotate.d/tedarik <<LOGROT
${APP_DIR}/storage/logs/*.log /var/log/tedarik-cron.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    copytruncate
}
LOGROT

log "laravel cache clear (NO config:cache — this app calls env() at runtime)"
sudo -u nginx php artisan optimize:clear

log "smoke test"
sudo -u nginx php artisan --version
curl -sS -o /dev/null -w "local http -> %{http_code}\n" -H "Host: ${DOMAIN}" http://127.0.0.1/ || true
systemctl --no-pager status nginx php-fpm postgresql | grep -E 'Active|●'

log "DONE"
echo "app: ${APP_DIR}"
echo "next: import DB dump, copy public/documents, set SAP_* in .env, then run"
echo "      php artisan migrate --force   (only on an EMPTY database)"
