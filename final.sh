#!/bin/bash
#
# install-zabbix-agent.sh
#
# Distro-agnostic installer for classic Zabbix Agent ("Agent 1", package name: zabbix-agent).
# Supports: Ubuntu, Debian, RHEL, CentOS, Rocky, AlmaLinux, Fedora,
#           Amazon Linux 2 / 2023, openSUSE / SLES.
#
# Usage:
#   sudo ./install-zabbix-agent.sh
#
# Override defaults via environment variables:
#   ZABBIX_VERSION=7.0 ZABBIX_SERVER_IP=10.0.0.5 ZABBIX_HOSTNAME=web01 \
#       sudo -E ./install-zabbix-agent.sh
#
set -euo pipefail

# ---------- CONFIG ----------
ZABBIX_VERSION="${ZABBIX_VERSION:-7.0}"            # Zabbix major.minor branch (7.0 = LTS, 7.4 = latest)
ZABBIX_SERVER_IP="${ZABBIX_SERVER_IP:-127.0.0.1}"  # IP/hostname of your Zabbix server or proxy
ZABBIX_HOSTNAME="${ZABBIX_HOSTNAME:-$(hostname)}"  # Hostname as registered in the Zabbix frontend
ZABBIX_LISTEN_PORT="${ZABBIX_LISTEN_PORT:-10050}"
# -----------------------------

log()  { echo -e "[$(date +'%H:%M:%S')] $*"; }
fail() { echo -e "[$(date +'%H:%M:%S')] ERROR: $*" >&2; exit 1; }

[ "$EUID" -eq 0 ] || fail "Please run as root (sudo ./install-zabbix-agent.sh)."

# ==============================================================================
# 1. DETECT OS
# ==============================================================================
log "=== Detecting OS ==="
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_ID_LIKE="${ID_LIKE:-}"
    OS_VERSION="${VERSION_ID:-}"
else
    fail "/etc/os-release not found — cannot reliably detect distro."
fi
log "Detected: ${PRETTY_NAME:-$OS_ID $OS_VERSION}"

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
log "=== Installing Zabbix Agent 1 (version branch ${ZABBIX_VERSION}) ==="
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
# 4. CONFIGURE AGENT 1
# ==============================================================================
log "=== Configuring Zabbix Agent 1 ==="
CONF_FILE="/etc/zabbix/zabbix_agentd.conf"

if [ -f "$CONF_FILE" ]; then
    cp "$CONF_FILE" "${CONF_FILE}.bak.$(date +%s)"
    
    # Configure Server parameter
    if grep -q "^Server=" "$CONF_FILE"; then
        sed -i "s/^Server=.*/Server=${ZABBIX_SERVER_IP}/" "$CONF_FILE"
    else
        echo "Server=${ZABBIX_SERVER_IP}" >> "$CONF_FILE"
    fi

    # Configure ServerActive parameter
    if grep -q "^ServerActive=" "$CONF_FILE"; then
        sed -i "s/^ServerActive=.*/ServerActive=${ZABBIX_SERVER_IP}/" "$CONF_FILE"
    else
        echo "ServerActive=${ZABBIX_SERVER_IP}" >> "$CONF_FILE"
    fi

    # Configure Hostname parameter
    if grep -q "^Hostname=" "$CONF_FILE"; then
        sed -i "s/^Hostname=.*/Hostname=${ZABBIX_HOSTNAME}/" "$CONF_FILE"
    else
        echo "Hostname=${ZABBIX_HOSTNAME}" >> "$CONF_FILE"
    fi

    # Configure ListenPort parameter
    if grep -q "^ListenPort=" "$CONF_FILE"; then
        sed -i "s/^ListenPort=.*/ListenPort=${ZABBIX_LISTEN_PORT}/" "$CONF_FILE"
    else
        echo "ListenPort=${ZABBIX_LISTEN_PORT}" >> "$CONF_FILE"
    fi

    log "Updated $CONF_FILE (backup saved alongside it)."
else
    fail "$CONF_FILE not found after install — package install may have failed silently."
fi

# ==============================================================================
# 5. ENABLE, START, VERIFY
# ==============================================================================
log "=== Enabling and starting zabbix-agent ==="
systemctl enable zabbix-agent
systemctl restart zabbix-agent
sleep 2

if systemctl is-active --quiet zabbix-agent; then
    log "zabbix-agent is running successfully."
else
    log "WARNING: zabbix-agent failed to start. Check: journalctl -u zabbix-agent -e"
fi

log "=== Done ==="
log "Server:     $ZABBIX_SERVER_IP"
log "Hostname:   $ZABBIX_HOSTNAME"
log "ListenPort: $ZABBIX_LISTEN_PORT"
