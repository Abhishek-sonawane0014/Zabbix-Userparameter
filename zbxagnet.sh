#!/bin/bash
#
# zabbix-setup-menu.sh
# Interactive Setup Script for Zabbix Agent (Version 7.4)
#
set -euo pipefail

# ---------- GLOBAL CONFIG ----------
ZABBIX_VERSION="7.4"
ZABBIX_SERVER_IP="${ZABBIX_SERVER_IP:-monitoring.leapswitch.com}"
ZABBIX_LISTEN_PORT="${ZABBIX_LISTEN_PORT:-10050}"

PRIMARY_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I | awk '{print $1}')
LAST_OCTET="${PRIMARY_IP##*.}"
[ -n "$LAST_OCTET" ] || LAST_OCTET="0"

SYS_HOSTNAME=$(hostname -s)
ZABBIX_HOSTNAME="${ZABBIX_HOSTNAME:-${SYS_HOSTNAME}-${LAST_OCTET}}"
# -----------------------------------

log()  { echo -e "[$(date +'%H:%M:%S')] $*"; }
fail() { echo -e "[$(date +'%H:%M:%S')] ERROR: $*" >&2; exit 1; }

[ "$EUID" -eq 0 ] || fail "Please run as root (e.g., sudo ./zabbix-setup-menu.sh)."

configure_base_agent() {
    log "Configuring /etc/zabbix/zabbix_agentd.conf..."
    CONF_FILE="/etc/zabbix/zabbix_agentd.conf"

    if [ -f "$CONF_FILE" ]; then
        cp "$CONF_FILE" "${CONF_FILE}.bak.$(date +%s)"

        grep -q "^Server=" "$CONF_FILE" && sed -i "s/^Server=.*/Server=${ZABBIX_SERVER_IP}/" "$CONF_FILE" || echo "Server=${ZABBIX_SERVER_IP}" >> "$CONF_FILE"
        grep -q "^ServerActive=" "$CONF_FILE" && sed -i "s/^ServerActive=.*/ServerActive=${ZABBIX_SERVER_IP}/" "$CONF_FILE" || echo "ServerActive=${ZABBIX_SERVER_IP}" >> "$CONF_FILE"
        grep -q "^Hostname=" "$CONF_FILE" && sed -i "s/^Hostname=.*/Hostname=${ZABBIX_HOSTNAME}/" "$CONF_FILE" || echo "Hostname=${ZABBIX_HOSTNAME}" >> "$CONF_FILE"
        grep -q "^ListenPort=" "$CONF_FILE" && sed -i "s/^ListenPort=.*/ListenPort=${ZABBIX_LISTEN_PORT}/" "$CONF_FILE" || echo "ListenPort=${ZABBIX_LISTEN_PORT}" >> "$CONF_FILE"

        log "Base configuration complete. Hostname set to: ${ZABBIX_HOSTNAME}"
    else
        fail "Configuration file $CONF_FILE not found."
    fi

    mkdir -p /etc/zabbix/zabbix_agentd.d/
    systemctl enable zabbix-agent
    systemctl restart zabbix-agent
}

install_ubuntu() {
    log "=== Installing Zabbix Agent ${ZABBIX_VERSION} on Ubuntu / Debian ==="
    export DEBIAN_FRONTEND=noninteractive
    
    # Remove older zabbix repository release package if present
    dpkg -P zabbix-release 2>/dev/null || true

    apt-get update -y
    apt-get install -y wget gnupg lsb-release ca-certificates

    local OS_ID OS_VERSION codename
    OS_ID=$(. /etc/os-release && echo "${ID:-ubuntu}")
    OS_VERSION=$(. /etc/os-release && echo "${VERSION_ID:-22.04}")
    codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")

    local repo_deb="zabbix-release_latest_${ZABBIX_VERSION}+${OS_ID}${OS_VERSION}_all.deb"
    local repo_url="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/${OS_ID}/pool/main/z/zabbix-release/${repo_deb}"

    if ! wget -q "$repo_url" -O /tmp/zabbix-release.deb; then
        repo_deb="zabbix-release_latest_${ZABBIX_VERSION}+${OS_ID}${codename}_all.deb"
        repo_url="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/${OS_ID}/pool/main/z/zabbix-release/${repo_deb}"
        wget -q "$repo_url" -O /tmp/zabbix-release.deb || fail "Could not fetch Zabbix 7.4 repository package."
    fi

    dpkg -i /tmp/zabbix-release.deb
    apt-get update -y
    apt-get install -y --allow-downgrades zabbix-agent

    configure_base_agent
    
    # Verify version after installation
    zabbix_agentd -V | head -n 1
}

install_redhat() {
    log "=== Installing Zabbix Agent ${ZABBIX_VERSION} on RedHat / Fedora / AlmaLinux / Rocky ==="
    local rhel_ver pkg_mgr="yum"
    rhel_ver=$(. /etc/os-release && echo "${VERSION_ID%%.*}")
    [ -z "$rhel_ver" ] && rhel_ver="8"
    command -v dnf >/dev/null 2>&1 && pkg_mgr="dnf"

    rpm -e zabbix-release 2>/dev/null || true

    rpm -Uvh --replacepkgs \
        "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/rhel/${rhel_ver}/x86_64/zabbix-release-latest-${ZABBIX_VERSION}.el${rhel_ver}.noarch.rpm" \
        || fail "Could not fetch Zabbix 7.4 repository RPM."

    $pkg_mgr clean all
    $pkg_mgr install -y zabbix-agent

    configure_base_agent
    
    # Verify version after installation
    zabbix_agentd -V | head -n 1
}

install_user_parameters() {
    log "=== Adding Additional UserParameters (Yum, Exim, MySQL) ==="

    mkdir -p /etc/zabbix/zabbix_agentd.d/

    cat << 'EOF' > /etc/zabbix/zabbix_agentd.d/userparameter_yum.conf
UserParameter=yum1.security,cat /tmp/security-updates.txt 2>/dev/null || echo 0
UserParameter=yum1.all,cat /tmp/all-updates.txt 2>/dev/null || echo 0
EOF

    cat << 'EOF' > /etc/zabbix/zabbix_agentd.d/userparameter_exim.conf
UserParameter=exim.queue,cat /tmp/eximcounttest.txt 2>/dev/null || echo 0
EOF

    (crontab -l 2>/dev/null | grep -v 'all-updates.txt' | grep -v 'eximcounttest.txt' || true; \
     echo "0 1 * * * yum list updates 2>/dev/null | grep -E '\.x86_64|\.i686|\.noarch' | wc -l > /tmp/all-updates.txt"; \
     echo "*/5 * * * * /usr/sbin/exim -bpc > /tmp/eximcounttest.txt 2>/dev/null || echo 0 > /tmp/eximcounttest.txt") | crontab -

    touch /tmp/security-updates.txt
    if command -v yum >/dev/null 2>&1; then
        yum list updates 2>/dev/null | grep -E '\.x86_64|\.i686|\.noarch' | wc -l > /tmp/all-updates.txt || echo "0" > /tmp/all-updates.txt
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get -s upgrade 2>/dev/null | grep -c '^Inst' > /tmp/all-updates.txt || echo "0" > /tmp/all-updates.txt
    else
        echo "0" > /tmp/all-updates.txt
    fi

    if [ -x /usr/sbin/exim ]; then
        /usr/sbin/exim -bpc > /tmp/eximcounttest.txt 2>/dev/null || echo "0" > /tmp/eximcounttest.txt
    else
        echo "0" > /tmp/eximcounttest.txt
    fi
    chmod 644 /tmp/all-updates.txt /tmp/security-updates.txt /tmp/eximcounttest.txt

    log "Setting up MySQL/MariaDB monitoring parameters..."
    zpassword=$(date +%s | sha256sum | base64 | head -c 12 ; echo)

    if command -v mysql >/dev/null 2>&1; then
        if [ -f /root/.my.cnf ]; then
            mysql -e "CREATE USER IF NOT EXISTS 'zbx_monitor'@'%' IDENTIFIED BY '${zpassword}';" || true
            mysql -e "GRANT USAGE,REPLICATION CLIENT,PROCESS,SHOW DATABASES,SHOW VIEW ON *.* TO 'zbx_monitor'@'%';" || true
            mysql -e "FLUSH PRIVILEGES;" || true
        else
            echo "Enter MySQL root password (press Enter if none):"
            read -sp "Password: " rootpasswd
            echo ""
            mysql -uroot -p"${rootpasswd}" -e "CREATE USER IF NOT EXISTS 'zbx_monitor'@'%' IDENTIFIED BY '${zpassword}';" || true
            mysql -uroot -p"${rootpasswd}" -e "GRANT USAGE,REPLICATION CLIENT,PROCESS,SHOW DATABASES,SHOW VIEW ON *.* TO 'zbx_monitor'@'%';" || true
            mysql -uroot -p"${rootpasswd}" -e "FLUSH PRIVILEGES;" || true
        fi
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

    systemctl restart zabbix-agent
    log "Additional UserParameters applied and Zabbix service restarted!"
}

# ==============================================================================
# MAIN MENU
# ==============================================================================
clear
echo "================================================="
echo "     ZABBIX AGENT SETUP MENU (Version 7.4)       "
echo "================================================="
echo "1) Install Zabbix Agent 7.4 for Ubuntu / Debian"
echo "2) Install Zabbix Agent 7.4 for RedHat / Fedora / AlmaLinux / Rocky"
echo "3) Configure Additional User Parameters (Yum, Exim, MySQL)"
echo "4) Exit"
echo "================================================="
read -rp "Please enter your choice [1-4]: " CHOICE

case "$CHOICE" in
    1)
        install_ubuntu
        ;;
    2)
        install_redhat
        ;;
    3)
        install_user_parameters
        ;;
    4)
        echo "Exiting script."
        exit 0
        ;;
    *)
        fail "Invalid selection. Please run the script again and select 1, 2, 3, or 4."
        ;;
esac
