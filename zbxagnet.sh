#!/bin/bash
#
# install-and-setup-zabbix.sh
#
# Combined installer and setup script for Zabbix Agent 1.
# - Installs Zabbix Agent 1 (zabbix-agent) on Ubuntu, Debian, RHEL, CentOS, Rocky, Alma, Fedora, Amazon Linux, openSUSE/SLES.
# - Configures base agent settings (/etc/zabbix/zabbix_agentd.conf).
# - Automatically formats Hostname as "<system_hostname>-<last_ip_octet>".
# - Sets up custom UserParameters and cronjobs for Yum and Exim monitoring.
# - Provisions a 'zbx_monitor' MySQL/MariaDB user and configures /etc/zabbix/.my.cnf.
#
# Usage:
#   sudo ./install-and-setup-zabbix.sh
#
# Override defaults via environment variables:
#   ZABBIX_VERSION=7.0 ZABBIX_SERVER_IP=monitoring.leapswitch.com \
#       sudo -E ./install-and-setup-zabbix.sh
#
set -euo pipefail

# ---------- CONFIG ----------
ZABBIX_VERSION="${ZABBIX_VERSION:-7.0}"                        # Zabbix major.minor branch (7.0 = LTS, 7.4 = latest)
ZABBIX_SERVER_IP="${ZABBIX_SERVER_IP:-monitoring.leapswitch.com}" # Server & ServerActive address
ZABBIX_LISTEN_PORT="${ZABBIX_LISTEN_PORT:-10050}"

# Determine primary IP address and extract the last octet
PRIMARY_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I | awk '{print $1}')
LAST_OCTET="${PRIMARY_IP##*.}"
[ -n "$LAST_OCTET" ] || LAST_OCTET="0"

# Set Hostname format: hostname-lastoctet (e.g., myserver-145)
SYS_HOSTNAME=$(hostname -s)
ZABBIX_HOSTNAME="${ZABBIX_HOSTNAME:-${SYS_HOSTNAME}-${LAST_OCTET}}"
# -----------------------------

log()  { echo -e "[$(date +'%H:%M:%S')] $*"; }
fail() { echo -e "[$(date +'%H:%M:%S')] ERROR: $*" >&2; exit 1; }

[ "$EUID" -eq 0 ] || fail "Please run as root (sudo ./install-and-setup-zabbix.sh)."

# ==============================================================================
# 1. DETECT OS
# ==============================================================================
log "=== Step 1: Detecting OS ==="
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_ID_LIKE="${ID_LIKE:-}"
    OS_VERSION="${VERSION_ID:-}"
else
    fail "/etc/os-release not found — cannot reliably detect distro."
fi
log "Detected: ${PRETTY_NAME:-$OS_ID $OS_VERSION}"
log "Configured Hostname: ${ZABBIX_HOSTNAME} (IP: ${PRIMARY_IP:-Unknown})"

# ==============================================================================
# 2. INSTALL FUNCTIONS PER DISTRO FAMILY
# ==============================================================================

install_debian_ubuntu() {
    local codename
    codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
    [ -n "$codename" ] || fail "Could not determine VERSION_CODENAME for $OS_ID."

    log "=== Installing Zabbix repo for $OS_ID $OS_VERSION ($codename) ==="
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y wget gnupg lsb-release ca-certificates

    local repo_deb="zabbix-release_latest_${ZABBIX_VERSION}+${OS_ID}${OS_VERSION}_all.deb"
    local repo_url="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/${OS_ID}/pool/main/z/zabbix-release/${repo_deb}"

    if ! wget -q "$repo_url" -O /tmp/zabbix-release.deb; then
        log "Exact match not found, trying codename-based path..."
        repo_deb="zabbix-release_latest_${ZABBIX_VERSION}+${OS_ID}${codename}_all.deb"
        repo_url="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/${OS_ID}/pool/main/z/zabbix-release/${repo_deb}"
        wget -q "$repo_url" -O /tmp/zabbix-release.deb || \
            fail "Could not fetch Zabbix repo package. Check https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/${OS_ID}/pool/main/z/zabbix-release/ for the exact filename."
    fi

    dpkg -i /tmp/zabbix-release.deb
    apt-get update -y
    apt-get install -y zabbix-agent
}

install_rhel_family() {
    local rhel_ver="${OS_VERSION%%.*}"
    local pkg_mgr="yum"
    command -v dnf >/dev/null 2>&1 && pkg_mgr="dnf"

    log "=== Installing Zabbix repo for $OS_ID $rhel_ver (using $pkg_mgr) ==="
    rpm -Uvh --replacepkgs \
        "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/rhel/${rhel_ver}/x86_64/zabbix-release-latest-${ZABBIX_VERSION}.el${rhel_ver}.noarch.rpm" \
        || fail "Could not fetch Zabbix repo RPM for $OS_ID $rhel_ver. Check https://www.zabbix.com/download for the correct URL."

    $pkg_mgr clean all
    $pkg_mgr install -y zabbix-agent
}

install_amazon_linux() {
    local pkg_mgr="yum"
    command -v dnf >/dev/null 2>&1 && pkg_mgr="dnf"
    local al_target="rhel/9"
    [ "$OS_VERSION" = "2" ] && al_target="rhel/7"

    log "=== Installing Zabbix repo for Amazon Linux $OS_VERSION (via ${al_target}) ==="
    rpm -Uvh --replacepkgs \
        "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/${al_target}/x86_64/zabbix-release-latest-${ZABBIX_VERSION}.$(echo "$al_target" | tr '/' '.' | sed 's/rhel\./el/').noarch.rpm" \
        || fail "Could not fetch Zabbix repo RPM for Amazon Linux $OS_VERSION."

    $pkg_mgr clean all
    $pkg_mgr install -y zabbix-agent
}

install_suse_family() {
    log "=== Installing Zabbix repo for $OS_ID $OS_VERSION (SUSE family) ==="
    zypper --non-interactive addrepo \
        "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/sles/${OS_VERSION%%.*}/x86_64/" zabbix || true
    zypper --gpg-auto-import-keys refresh
    zypper --non-interactive install zabbix-agent || \
        fail "Could not install zabbix-agent on $OS_ID $OS_VERSION."
}

# ==============================================================================
# 3. DISPATCH BY DISTRO
# ==============================================================================
log "=== Step 2: Installing Zabbix Agent 1 (version branch ${ZABBIX_VERSION}) ==="
case "$OS_ID" in
    ubuntu|debian)
        install_debian_ubuntu
        ;;
    rhel|centos|almalinux|rocky|fedora)
        install_rhel_family
        ;;
    amzn)
        install_amazon_linux
        ;;
    sles|opensuse-leap|opensuse-tumbleweed|sled)
        install_suse_family
        ;;
    *)
        case "$OS_ID_LIKE" in
            *debian*)
                install_debian_ubuntu
                ;;
            *rhel*fedora*|*fedora*rhel*|*rhel*)
                install_rhel_family
                ;;
            *suse*)
                install_suse_family
                ;;
            *)
                fail "Unsupported OS: $OS_ID (ID_LIKE=$OS_ID_LIKE)."
                ;;
        esac
        ;;
esac

# ==============================================================================
# 4. CONFIGURE AGENT 1 BASE SETTINGS
# ==============================================================================
log "=== Step 3: Configuring Zabbix Agent 1 Base Settings ==="
CONF_FILE="/etc/zabbix/zabbix_agentd.conf"

if [ -f "$CONF_FILE" ]; then
    cp "$CONF_FILE" "${CONF_FILE}.bak.$(date +%s)"
    
    if grep -q "^Server=" "$CONF_FILE"; then
        sed -i "s/^Server=.*/Server=${ZABBIX_SERVER_IP}/" "$CONF_FILE"
    else
        echo "Server=${ZABBIX_SERVER_IP}" >> "$CONF_FILE"
    fi

    if grep -q "^ServerActive=" "$CONF_FILE"; then
        sed -i "s/^ServerActive=.*/ServerActive=${ZABBIX_SERVER_IP}/" "$CONF_FILE"
    else
        echo "ServerActive=${ZABBIX_SERVER_IP}" >> "$CONF_FILE"
    fi

    if grep -q "^Hostname=" "$CONF_FILE"; then
        sed -i "s/^Hostname=.*/Hostname=${ZABBIX_HOSTNAME}/" "$CONF_FILE"
    else
        echo "Hostname=${ZABBIX_HOSTNAME}" >> "$CONF_FILE"
    fi

    if grep -q "^ListenPort=" "$CONF_FILE"; then
        sed -i "s/^ListenPort=.*/ListenPort=${ZABBIX_LISTEN_PORT}/" "$CONF_FILE"
    else
        echo "ListenPort=${ZABBIX_LISTEN_PORT}" >> "$CONF_FILE"
    fi

    log "Updated $CONF_FILE (backup saved alongside it)."
else
    fail "$CONF_FILE not found after install — package install may have failed silently."
fi

# Ensure Zabbix configuration include directory exists
mkdir -p /etc/zabbix/zabbix_agentd.d/

# ==============================================================================
# 5. EXIM & YUM USERPARAMETERS & CRONJOBS
# ==============================================================================
log "=== Step 4: Setting up Exim and Yum UserParameters ==="

cat << 'EOF' > /etc/zabbix/zabbix_agentd.d/userparameter_yum.conf
UserParameter=yum1.security,cat /tmp/security-updates.txt 2>/dev/null || echo 0
UserParameter=yum1.all,cat /tmp/all-updates.txt 2>/dev/null || echo 0
EOF

cat << 'EOF' > /etc/zabbix/zabbix_agentd.d/userparameter_exim.conf
UserParameter=exim.queue,cat /tmp/eximcounttest.txt 2>/dev/null || echo 0
EOF

log "Adding Cronjobs for Yum and Exim..."
(crontab -l 2>/dev/null | grep -v 'all-updates.txt' | grep -v 'eximcounttest.txt' || true; \
 echo "0 1 * * * yum list updates 2>/dev/null | grep -E '\.x86_64|\.i686|\.noarch' | wc -l > /tmp/all-updates.txt"; \
 echo "*/5 * * * * /usr/sbin/exim -bpc > /tmp/eximcounttest.txt 2>/dev/null || echo 0 > /tmp/eximcounttest.txt") | crontab -

log "Initializing cached data files for Yum and Exim..."
if command -v yum >/dev/null 2>&1; then
    yum list updates 2>/dev/null | grep -E '\.x86_64|\.i686|\.noarch' | wc -l > /tmp/all-updates.txt || echo "0" > /tmp/all-updates.txt
elif command -v dnf >/dev/null 2>&1; then
    dnf list updates 2>/dev/null | grep -E '\.x86_64|\.i686|\.noarch' | wc -l > /tmp/all-updates.txt || echo "0" > /tmp/all-updates.txt
else
    echo "0" > /tmp/all-updates.txt
fi

touch /tmp/security-updates.txt

if [ -x /usr/sbin/exim ]; then
    /usr/sbin/exim -bpc > /tmp/eximcounttest.txt 2>/dev/null || echo "0" > /tmp/eximcounttest.txt
else
    echo "0" > /tmp/eximcounttest.txt
fi

chmod 644 /tmp/all-updates.txt /tmp/security-updates.txt /tmp/eximcounttest.txt

# ==============================================================================
# 6. MYSQL MONITORING SETUP
# ==============================================================================
log "=== Step 5: Setting up MySQL Zabbix Monitoring ==="

rm -f /etc/zabbix/zabbix_agentd.d/userparameter_mysql.conf*

if [ -f /etc/zabbix/.my.cnf ]; then
    cp /etc/zabbix/.my.cnf "/etc/zabbix/.my.cnf_old.$(date +%s)"
fi

zpassword=$(date +%s | sha256sum | base64 | head -c 12 ; echo)

if command -v mysql >/dev/null 2>&1; then
    if [ -f /root/.my.cnf ]; then
        mysql -e "CREATE USER IF NOT EXISTS 'zbx_monitor'@'%' IDENTIFIED BY '${zpassword}';" || true
        mysql -e "GRANT USAGE,REPLICATION CLIENT,PROCESS,SHOW DATABASES,SHOW VIEW ON *.* TO 'zbx_monitor'@'%';" || true
        mysql -e "FLUSH PRIVILEGES;" || true
    else
        echo "Please enter root user MySQL password (press Enter if no password is set):"
        read -sp "Password: " rootpasswd
        echo ""
        mysql -uroot -p"${rootpasswd}" -e "CREATE USER IF NOT EXISTS 'zbx_monitor'@'%' IDENTIFIED BY '${zpassword}';" || true
        mysql -uroot -p"${rootpasswd}" -e "GRANT USAGE,REPLICATION CLIENT,PROCESS,SHOW DATABASES,SHOW VIEW ON *.* TO 'zbx_monitor'@'%';" || true
        mysql -uroot -p"${rootpasswd}" -e "FLUSH PRIVILEGES;" || true
    fi
else
    log "MySQL client not found locally. Skipping MySQL user creation on DB server; writing config file."
fi

cat << EOF > /etc/zabbix/.my.cnf
[client]
user=zbx_monitor
password=$zpassword
EOF

chmod 600 /etc/zabbix/.my.cnf
chown zabbix:zabbix /etc/zabbix/.my.cnf 2>/dev/null || true

cat << 'EOF' > /etc/zabbix/zabbix_agentd.d/template_db_mysql.conf
UserParameter=mysql.ping[*],HOME=/etc/zabbix mysqladmin -h"$1" -P"$2" ping
UserParameter=mysql.get_status_variables[*],HOME=/etc/zabbix mysql -h"$1" -P"$2" -sNX -e "show global status"
UserParameter=mysql.version[*],HOME=/etc/zabbix mysqladmin -s -h"$1" -P"$2" version
UserParameter=mysql.db.discovery[*],HOME=/etc/zabbix mysql -h"$1" -P"$2" -sN -e "show databases"
UserParameter=mysql.dbsize[*],HOME=/etc/zabbix mysql -h"$1" -P"$2" -sN -e "SELECT SUM(DATA_LENGTH + INDEX_LENGTH) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA='$3'"
UserParameter=mysql.replication.discovery[*],HOME=/etc/zabbix mysql -h"$1" -P"$2" -sNX -e "show slave status"
UserParameter=mysql.slave_status[*],HOME=/etc/zabbix mysql -h"$1" -P"$2" -sNX -e "show slave status"
EOF

# ==============================================================================
# 7. ENABLE, START, VERIFY
# ==============================================================================
log "=== Step 6: Enabling and starting zabbix-agent ==="
systemctl enable zabbix-agent
systemctl restart zabbix-agent
sleep 2

if systemctl is-active --quiet zabbix-agent; then
    log "zabbix-agent is running successfully."
else
    log "WARNING: zabbix-agent failed to start. Check: journalctl -u zabbix-agent -e"
fi

log "=== Complete Setup Succeeded ==="
log "Server:       $ZABBIX_SERVER_IP"
log "ServerActive: $ZABBIX_SERVER_IP"
log "Hostname:     $ZABBIX_HOSTNAME"
log "ListenPort:   $ZABBIX_LISTEN_PORT"
