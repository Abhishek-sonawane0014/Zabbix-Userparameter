#!/bin/bash

# Ensure Zabbix configuration directory exists
mkdir -p /etc/zabbix/zabbix_agentd.d/

# ==============================================================================
# 1. EXIM & YUM USERPARAMETERS & CRONJOBS
# ==============================================================================
echo ""
echo "--- Setting up Exim and Yum UserParameters ---"

# Create userparameter_yum.conf with updated parameter names
cat << 'EOF' > /etc/zabbix/zabbix_agentd.d/userparameter_yum.conf
UserParameter=yum1.security,cat /tmp/security-updates.txt
UserParameter=yum1.all,cat /tmp/all-updates.txt
EOF

# Create userparameter_exim.conf
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
# 2. MYSQL MONITORING SETUP
# ==============================================================================
echo ""
echo "--- Setting up MySQL Zabbix Monitoring ---"

# Remove old mysql userparameters if present
rm -rf /etc/zabbix/zabbix_agentd.d/userparameter_mysql.conf*

# Backup existing .my.cnf if present
if [ -f /etc/zabbix/.my.cnf ]; then
    cp /etc/zabbix/.my.cnf /etc/zabbix/.my.cnf_old
fi

# Generate random password
zpassword=$(date +%s | sha256sum | base64 | head -c 12 ; echo)

# Create Zabbix MySQL user
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

# Store credentials in /etc/zabbix/.my.cnf and restrict permissions
cat << EOF > /etc/zabbix/.my.cnf
[client]
user=zbx_monitor
password=$zpassword
EOF
chmod 600 /etc/zabbix/.my.cnf
chown zabbix:zabbix /etc/zabbix/.my.cnf 2>/dev/null || true

# Write exact Zabbix 4.2 MySQL UserParameters
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
# 3. RESTART AGENT
# ==============================================================================
echo ""
echo "Restarting Zabbix Agent..."
systemctl restart zabbix-agent 2>/dev/null || service zabbix-agent restart

echo ""
echo "=== Complete Setup Succeeded ==="
