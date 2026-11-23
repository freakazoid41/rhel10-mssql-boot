#!/usr/bin/env bash
# RHEL 10 — SQL Server 2025 + ODBC 18 + PHP sqlsrv/pdo_sqlsrv offline installer
# Repo: https://github.com/freakazoid41/rhel10-mssql-boot  (temporary, delete after use)
set -euo pipefail

BASE="${BASE:-https://github.com/freakazoid41/rhel10-mssql-boot/releases/download/v1}"
WORK="${WORK:-/tmp/mssql-bundle}"
SA_PASS="${SA_PASS:?export SA_PASS='YourStrong!Passw0rd' first}"
MSSQL_PID="${MSSQL_PID:-Developer}"
MSSQL_MEM_MB="${MSSQL_MEM_MB:-3072}"
MSSQL_COLLATION="${MSSQL_COLLATION:-Turkish_CI_AS}"

FILES=(
  mssql-server-17.0.5065.9-3.x86_64.rpm
  mssql-server-selinux-17.0.5065.9-3.x86_64.rpm
  msodbcsql18-18.7.1.1-1.x86_64.rpm
  mssql-tools18-18.7.1.1-1.x86_64.rpm
  unixODBC-devel-2.3.12-5.el10.x86_64.rpm
  sqlsrv-5.13.3.tgz
  pdo_sqlsrv-5.13.3.tgz
  microsoft-2025.asc
  SHA256SUMS
)

mkdir -p "$WORK"; cd "$WORK"

echo "==> downloading bundle"
for f in "${FILES[@]}"; do
  echo "   $f"
  curl -fL --retry 5 --retry-delay 3 -O "$BASE/$f"
done

echo "==> verifying checksums"
sha256sum -c --ignore-missing SHA256SUMS

echo "==> importing Microsoft signing key"
rpm --import microsoft-2025.asc

echo "==> base dependencies (EUS AppStream/BaseOS)"
dnf install -y unixODBC pkgconf-pkg-config gcc gcc-c++ make unzip \
  php php-cli php-fpm php-common php-pdo php-pgsql php-mbstring php-xml php-gd \
  php-pecl-zip php-intl php-bcmath php-opcache php-soap php-process php-devel php-pear

echo "==> unixODBC headers (CRB replacement)"
dnf install -y ./unixODBC-devel-2.3.12-5.el10.x86_64.rpm

echo "==> Microsoft ODBC driver 18 + tools"
ACCEPT_EULA=Y dnf install -y ./msodbcsql18-18.7.1.1-1.x86_64.rpm ./mssql-tools18-18.7.1.1-1.x86_64.rpm

echo "==> SQL Server 2025 engine"
dnf install -y ./mssql-server-17.0.5065.9-3.x86_64.rpm ./mssql-server-selinux-17.0.5065.9-3.x86_64.rpm

echo "==> first-time setup (collation: $MSSQL_COLLATION)"
ACCEPT_EULA=Y MSSQL_PID="$MSSQL_PID" MSSQL_SA_PASSWORD="$SA_PASS" MSSQL_COLLATION="$MSSQL_COLLATION" \
  /opt/mssql/bin/mssql-conf -n setup

systemctl enable --now mssql-server
/opt/mssql/bin/mssql-conf set memory.memorylimitmb "$MSSQL_MEM_MB"
systemctl restart mssql-server

echo "==> building PHP drivers"
pecl install ./sqlsrv-5.13.3.tgz ./pdo_sqlsrv-5.13.3.tgz
echo 'extension=sqlsrv.so'     > /etc/php.d/30-sqlsrv.ini
echo 'extension=pdo_sqlsrv.so' > /etc/php.d/30-pdo_sqlsrv.ini
systemctl restart php-fpm 2>/dev/null || true

echo "==> verification"
php -m | grep -Ei 'sqlsrv|pgsql' || true
systemctl is-active mssql-server
/opt/mssql-tools18/bin/sqlcmd -S 127.0.0.1 -U sa -P "$SA_PASS" -C \
  -Q "SELECT @@VERSION; SELECT SERVERPROPERTY('Collation');"

echo
echo "DONE. Next: create the app database/login, then point Laravel at DB_CONNECTION=sqlsrv."
