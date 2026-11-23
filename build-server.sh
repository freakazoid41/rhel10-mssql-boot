#!/usr/bin/env bash
# gdzsatgun — phase 1 build: MSSQL 2025 + PHP 8.3 + nginx + php-fpm
# Everything pulled from GitHub (Microsoft + Remi are firewalled).
set -euo pipefail

BASE="https://github.com/freakazoid41/rhel10-mssql-boot/releases/download/v1"
WORK="/root/mssql-bundle"
MSSQL_PID="${MSSQL_PID:-Developer}"
MSSQL_MEM_MB="${MSSQL_MEM_MB:-3072}"
MSSQL_COLLATION="${MSSQL_COLLATION:-Turkish_CI_AS}"

log(){ echo -e "\n\033[1;36m==> $*\033[0m"; }
die(){ echo -e "\033[1;31m!! $*\033[0m"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"
timedatectl set-timezone Europe/Istanbul || true

log "repos sanity"
dnf -C repolist | grep -qE 'appstream' || die "AppStream repo not enabled"

log "download bundle"
mkdir -p "$WORK"; cd "$WORK"
for f in \
  mssql-server-17.0.5065.9-3.x86_64.rpm \
  mssql-server-selinux-17.0.5065.9-3.x86_64.rpm \
  msodbcsql18-18.7.1.1-1.x86_64.rpm \
  mssql-tools18-18.7.1.1-1.x86_64.rpm \
  unixODBC-devel-2.3.12-5.el10.x86_64.rpm \
  sqlsrv-5.13.3.tgz \
  pdo_sqlsrv-5.13.3.tgz \
  microsoft-2025.asc \
  SHA256SUMS ; do
  echo "   $f"
  curl -fL --retry 5 --retry-delay 3 -O "$BASE/$f"
done
sha256sum -c --ignore-missing SHA256SUMS || die "checksum mismatch"

log "base packages"
dnf install -y gcc gcc-c++ make unzip tar pkgconf-pkg-config unixODBC \
  openssl policycoreutils-python-utils

log "PHP 8.3 + extensions"
dnf install -y php php-cli php-fpm php-common php-pdo php-pgsql php-mbstring \
  php-xml php-gd php-pecl-zip php-intl php-bcmath php-opcache php-soap \
  php-process php-odbc php-devel php-pear

log "nginx"
dnf install -y nginx

log "microsoft key"
rpm --import microsoft-2025.asc

log "unixODBC headers (CRB replacement)"
dnf install -y ./unixODBC-devel-2.3.12-5.el10.x86_64.rpm

log "ODBC driver 18 + tools"
ACCEPT_EULA=Y dnf install -y ./msodbcsql18-18.7.1.1-1.x86_64.rpm ./mssql-tools18-18.7.1.1-1.x86_64.rpm
grep -q '/opt/mssql-tools18/bin' /etc/profile.d/mssql-tools.sh 2>/dev/null || \
  echo 'export PATH="$PATH:/opt/mssql-tools18/bin"' > /etc/profile.d/mssql-tools.sh

log "SQL Server 2025 engine"
dnf install -y ./mssql-server-17.0.5065.9-3.x86_64.rpm ./mssql-server-selinux-17.0.5065.9-3.x86_64.rpm

log "first-time setup"
if [ ! -d /var/opt/mssql/data ]; then
  SA_PASS="Aa1!$(openssl rand -hex 8)"
  printf '%s\n' "$SA_PASS" > /root/mssql-sa-password.txt
  chmod 600 /root/mssql-sa-password.txt
  ACCEPT_EULA=Y MSSQL_PID="$MSSQL_PID" MSSQL_SA_PASSWORD="$SA_PASS" MSSQL_COLLATION="$MSSQL_COLLATION" \
    /opt/mssql/bin/mssql-conf -n setup
  echo "SA password saved to /root/mssql-sa-password.txt"
else
  echo "already configured, skipping setup"
fi

systemctl enable --now mssql-server
/opt/mssql/bin/mssql-conf set memory.memorylimitmb "$MSSQL_MEM_MB" || true
systemctl restart mssql-server

log "PHP sqlsrv drivers"
pecl install ./sqlsrv-5.13.3.tgz ./pdo_sqlsrv-5.13.3.tgz </dev/null
echo 'extension=sqlsrv.so'     > /etc/php.d/30-sqlsrv.ini
echo 'extension=pdo_sqlsrv.so' > /etc/php.d/30-pdo_sqlsrv.ini

log "php limits + fpm pool"
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
sed -i 's/^user = .*/user = nginx/; s/^group = .*/group = nginx/' /etc/php-fpm.d/www.conf
sed -i 's/^listen.owner = .*/listen.owner = nginx/; s/^listen.group = .*/listen.group = nginx/' /etc/php-fpm.d/www.conf
sed -i 's/^listen = .*/listen = \/run\/php-fpm\/www.sock/' /etc/php-fpm.d/www.conf
sed -i 's/^;*listen.mode = .*/listen.mode = 0660/' /etc/php-fpm.d/www.conf
systemctl enable --now php-fpm

log "nginx + firewall"
systemctl enable --now nginx
firewall-cmd --permanent --add-service=http --permanent --add-service=https >/dev/null 2>&1 || true
firewall-cmd --reload >/dev/null 2>&1 || true

log "VERIFY"
php -v | head -2
echo "--- php modules:"
php -m | grep -Ei 'pdo|pgsql|sqlsrv|mbstring|gd|zip|xml|curl|intl|bcmath|opcache|soap' | tr '\n' ' '; echo
php-fpm -t
nginx -t
systemctl is-active mssql-server php-fpm nginx
ss -tlnp | grep -E ':(80|443|1433)\b' || true
SA_PASS="$(cat /root/mssql-sa-password.txt)"
/opt/mssql-tools18/bin/sqlcmd -S 127.0.0.1 -U sa -P "$SA_PASS" -C \
  -Q "SELECT @@VERSION; SELECT SERVERPROPERTY('Collation');" || true

echo
echo "PASSWORDS: /root/mssql-sa-password.txt"
echo "PHASE 1 DONE."
