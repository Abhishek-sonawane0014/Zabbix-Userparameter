
Claude finished the response

#!/bin/bash # Ensure Zabbix configuration directory exists mkdir -p /etc/zabbix/zabbix_agentd.d/ # ============================================================================== # 1. EXIM & YUM USERPARAMETERS & CRONJOBS # =====================================================================

pasted



Message collapsed
Thought for 5s
I'll combine these into a single comprehensive script that detects the OS, installs the Zabbix agent, and sets up Exim/Yum/MySQL monitoring.

Created a file, ran a command, read a file
This combines OS detection, Zabbix Agent installation, config, and the Exim/Yum/MySQL UserParameter setup into one script. Run it as sudo ./setup-zabbix-full.sh (optionally with ZABBIX_SERVER_IP=... ZABBIX_HOSTNAME=... env vars). A few things worth double-checking before you run it in production:

The MySQL section creates a zbx_monitor user with a randomly generated password — it'll prompt for the root MySQL password unless /root/.my.cnf already exists.
It assumes a Debian/Ubuntu or RHEL-family host; other distros will exit with an error.
It backs up zabbix_agentd.conf and .my.cnf before overwriting them.

Setup zabbix full
SH 


Write a message…


Claude is AI and can make mistakes.
Setup zabbix full · SH
Copied
#!/bin/bash
#
# setup-zabbix-full.sh
#
# Combined script that:
#   1. Detects the Linux distro
#   2. Installs the Zabbix Agent via the official Zabbix repo
#   3. Configures the agent (Server/ServerActive/Hostname)
#   4. Sets up Exim, Yum, and MySQL UserParameters + cronjobs
#   5. Restarts the Zabbix Agent
#
# Usage:
#   sudo ./setup-zabbix-full.sh
#
# Override defaults via environment variables, e.g.:
#   ZABBIX_VERSION=7.4 ZABBIX_SERVER_IP=10.0.0.5 sudo -E ./setup-zabbix-full.sh
#
set -e
 
# ---------- CONFIG (edit these or pass as env vars) ----------
ZABBIX_VERSION="${ZABBIX_VERSION:-7.4}"           # Zabbix major.minor version
ZABBIX_SERVER_IP="${ZABBIX_SERVER_IP:-127.0.0.1}" # IP/hostname of your Zabbix server
ZABBIX_HOSTNAME="${ZABBIX_HOSTNAME:-$(hostname)}" # Hostname registered in Zabbix
# ---------------------------------------------------------------
 
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script as root (use sudo)."
    exit 1
fi
 
# ==============================================================================
# 0. OS DETECTION
# ==============================================================================
echo "=== OS Information ==="
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "Name: $NAME"
    echo "Version: $VERSION"
    echo "ID: $ID"
    OS_ID="$ID"
    OS_VERSION="$VERSION_ID"
elif type lsb_release >/dev/null 2>&1; then
    lsb_release -a
    OS_ID=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
    OS_VERSION=$(lsb_release -rs)
elif [ -f /etc/lsb-release ]; then
    . /etc/lsb-release
    echo "Name: $DISTRIB_ID"
    echo "Version: $DISTRIB_RELEASE"
    OS_ID=$(echo "$DISTRIB_ID" | tr '[:upper:]' '[:lower:]')
    OS_VERSION="$DISTRIB_RELEASE"
else
    echo "Cannot detect OS via standard files. Falling back to uname:"
    uname -a
    echo "Aborting: unable to determine OS_ID/OS_VERSION needed for package install."
    exit 1
fi
echo "Detected: $OS_ID $OS_VERSION"
 
# ==============================================================================
# 1. INSTALL ZABBIX AGENT (distro-specific)
# ==============================================================================
install_debian_ubuntu() {
    local codename
    codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    echo "=== Installing Zabbix repo for $OS_ID $OS_VERSION ($codename) ==="
    apt-get update -y
    apt-get install -y wget gnupg
    REPO_DEB="zabbix-release_latest_${ZABBIX_VERSION}+${OS_ID}${OS_VERSION}_all.deb"
    REPO_URL="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/${OS_ID}/pool/main/z/zabbix-release/${REPO_DEB}"
    wget -q "$REPO_URL" -O /tmp/zabbix-release.deb || {
        echo "Could not fetch $REPO_URL"
        echo "Check available versions at https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/${OS_ID}/pool/main/z/zabbix-release/"
        exit 1
    }
    dpkg -i /tmp/zabbix-release.deb
    apt-get update -y
    apt-get install -y zabbix-agent
}
 
install_rhel_family() {
    local rhel_ver="${OS_VERSION%%.*}"
    echo "=== Installing Zabbix repo for $OS_ID $rhel_ver ==="
    rpm -Uvh "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/rhel/${rhel_ver}/x86_64/zabbix-release-latest-${ZABBIX_VERSION}.el${rhel_ver}.noarch.rpm" || {
        echo "Could not fetch Zabbix repo RPM. Check https://www.zabbix.com/download for the correct URL for your OS."
        exit 1
    }
    if command -v dnf >/dev/null 2>&1; then
        dnf clean all
        dnf install -y zabbix-agent
    else
        yum clean all
        yum install -y zabbix-agent
    fi
}
 
echo ""
echo "--- Installing Zabbix Agent ---"
case "$OS_ID" in
    ubuntu|debian)
        install_debian_ubuntu
        ;;
    rhel|centos|almalinux|rocky|fedora)
        install_rhel_family
        ;;
    *)
        echo "Unsupported or unrecognized OS: $OS_ID"
        echo "See https://www.zabbix.com/download for manual install instructions."
        exit 1
        ;;
esac
 
# ==============================================================================
# 2. CONFIGURE ZABBIX AGENT
# ==============================================================================
echo ""
echo "--- Configuring Zabbix Agent ---"
CONF_FILE="/etc/zabbix/zabbix_agentd.conf"
if [ -f "$CONF_FILE" ]; then
    cp "$CONF_FILE" "${CONF_FILE}.bak.$(date +%s)"
    sed -i "s/^Server=.*/Server=${ZABBIX_SERVER_IP}/" "$CONF_FILE"
    sed -i "s/^ServerActive=.*/ServerActive=${ZABBIX_SERVER_IP}/" "$CONF_FILE"
    sed -i "s/^Hostname=.*/Hostname=${ZABBIX_HOSTNAME}/" "$CONF_FILE"
    echo "Updated $CONF_FILE (backup saved alongside it)."
else
    echo "Warning: $CONF_FILE not found. Skipping config update."
fi
 
# Ensure the userparameter directory exists (in case the package didn't create it)
mkdir -p /etc/zabbix/zabbix_agentd.d/
 
# ==============================================================================
# 3. EXIM & YUM USERPARAMETERS & CRONJOBS
# ==============================================================================
echo ""
echo "--- Setting up Exim and Yum UserParameters ---"
 
cat << 'EOF' > /etc/zabbix/zabbix_agentd.d/userparameter_yum.conf
UserParameter=yum1.security,cat /tmp/security-updates.txt
UserParameter=yum1.all,cat /tmp/all-updates.txt
EOF
 
cat << 'EOF' > /etc/zabbix/zabbix_agentd.d/userparameter_exim.conf
UserParameter=exim.queue,cat /tmp/eximcounttest.txt 2>/dev/null || echo 0
EOF
 
echo "Adding Cronjobs for Yum and Exim..."
(crontab -l 2>/dev/null; echo "0 1 * * * yum list updates | grep '\.x86_64\|\.i686' | wc -l > /tmp/all-updates.txt") | crontab -
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/sbin/exim -bpc > /tmp/eximcounttest.txt") | crontab -
 
echo "Initializing data files for Yum and Exim..."
yum list updates 2>/dev/null | grep '\.x86_64\|\.i686' | wc -l > /tmp/all-updates.txt
touch /tmp/security-updates.txt
 
if [ -x /usr/sbin/exim ]; then
    /usr/sbin/exim -bpc > /tmp/eximcounttest.txt
else
    echo "0" > /tmp/eximcounttest.txt
fi
 
# ==============================================================================
# 4. MYSQL MONITORING SETUP
# ==============================================================================
echo ""
echo "--- Setting up MySQL Zabbix Monitoring ---"
 
rm -rf /etc/zabbix/zabbix_agentd.d/userparameter_mysql.conf*
 
if [ -f /etc/zabbix/.my.cnf ]; then
    cp /etc/zabbix/.my.cnf /etc/zabbix/.my.cnf_old
fi
 
zpassword=$(date +%s | sha256sum | base64 | head -c 12 ; echo)
 
if [ -f /root/.my.cnf ]; then
    mysql -e "CREATE USER 'zbx_monitor'@'%' IDENTIFIED BY '${zpassword}';"
    mysql -e "GRANT USAGE,REPLICATION CLIENT,PROCESS,SHOW DATABASES,SHOW VIEW ON *.* TO 'zbx_monitor'@'%';"
    mysql -e "FLUSH PRIVILEGES;"
else
    echo "Please enter root user MySQL password!"
    echo "Note: password will be hidden when typing"
    read -sp "Password: " rootpasswd
    echo ""
    mysql -uroot -p${rootpasswd} -e "CREATE USER 'zbx_monitor'@'%' IDENTIFIED BY '${zpassword}';"
    mysql -uroot -p${rootpasswd} -e "GRANT USAGE,REPLICATION CLIENT,PROCESS,SHOW DATABASES,SHOW VIEW ON *.* TO 'zbx_monitor'@'%';"
    mysql -uroot -p${rootpasswd} -e "FLUSH PRIVILEGES;"
fi
 
cat << EOF > /etc/zabbix/.my.cnf
[client]
user=zbx_monitor
password=$zpassword
EOF
chmod 600 /etc/zabbix/.my.cnf
chown zabbix:zabbix /etc/zabbix/.my.cnf 2>/dev/null || true
 
cat << 'EOF' > /etc/zabbix/zabbix_agentd.d/template_db_mysql.conf
#template_db_mysql.conf created by Zabbix for "Template DB MySQL" and Zabbix 4.2
#For OS Linux: You need create .my.cnf in zabbix-agent home directory (/var/lib/zabbix by default)
#For OS Windows: You need add PATH to mysql and mysqladmin and create my.cnf in %WINDIR%\my.cnf,C:\my.cnf,BASEDIR\my.cnf https://dev.mysql.com/doc/refman/5.7/en/option-files.html
#The file must have three strings:
#[client]
#user=zbx_monitor
#password=<password>
#
#Default below
UserParameter=mysql.ping[*],HOME=/etc/zabbix mysqladmin -h"$1" -P"$2" ping
UserParameter=mysql.get_status_variables[*],HOME=/etc/zabbix mysql -h"$1" -P"$2" -sNX -e "show global status"
UserParameter=mysql.version[*],HOME=/etc/zabbix mysqladmin -s -h"$1" -P"$2" version
UserParameter=mysql.db.discovery[*],HOME=/etc/zabbix mysql -h"$1" -P"$2" -sN -e "show databases"
UserParameter=mysql.dbsize[*],HOME=/etc/zabbix mysql -h"$1" -P"$2" -sN -e "SELECT SUM(DATA_LENGTH + INDEX_LENGTH) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA='$3'"
UserParameter=mysql.replication.discovery[*],HOME=/etc/zabbix mysql -h"$1" -P"$2" -sNX -e "show slave status"
UserParameter=mysql.slave_status[*],HOME=/etc/zabbix mysql -h"$1" -P"$2" -sNX -e "show slave status"
EOF
 
# ==============================================================================
# 5. ENABLE & RESTART AGENT
# ==============================================================================
echo ""
echo "--- Enabling and restarting Zabbix Agent ---"
systemctl enable zabbix-agent 2>/dev/null || true
systemctl restart zabbix-agent 2>/dev/null || service zabbix-agent restart
systemctl status zabbix-agent --no-pager 2>/dev/null || true
 
echo ""
echo "=== Complete Setup Succeeded ==="
echo "Server:   $ZABBIX_SERVER_IP"
echo "Hostname: $ZABBIX_HOSTNAME"
echo "Make sure this host is added in the Zabbix web UI with a matching hostname."
 
