#!/bin/bash

# Ensure Zabbix configuration directory exists
mkdir -p /etc/zabbix/zabbix_agentd.d/

# ==============================================================================
# 1. EXIM & YUM USERPARAMETERS & CRONJOBS
# ==============================================================================
echo ""
echo "--- Setting up Exim and Yum UserParameters ---"

# Create userparameter_yum.conf
cat << 'EOF' > /etc/zabbix/zabbix_agentd.d/userparameter_yum.conf
UserParameter=yum.updates,cat /tmp/all-updates.txt 2>/dev/null || echo 0
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
echo > /etc/zabbix/.my.cnf

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

# Write MySQL UserParameters
cat << 'EOF' > /etc/zabbix/zabbix_agentd.d/template_db_mysql.conf
UserParameter=mysql.ping,mysqladmin --defaults-extra-file=/etc/zabbix/.my.cnf ping | grep -c alive
UserParameter=mysql.version,mysql -V
UserParameter=mysql.status[*],echo "show global status like '$1';" | mysql --defaults-extra-file=/etc/zabbix/.my.cnf -N | awk '{print $$2}'
EOF

# ==============================================================================
# 3. RESTART AGENT
# ==============================================================================
echo ""
echo "Restarting Zabbix Agent..."
systemctl restart zabbix-agent 2>/dev/null || service zabbix-agent restart

echo ""
echo "=== Complete Setup Succeeded ==="
