FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# Basis-Tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    jq \
    sudo \
    procps \
    net-tools \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

# ---- FIX: Syslog Dummy (wichtig gegen PVE Fehler) ----
RUN mkdir -p /dev && ln -sf /dev/null /dev/log

# Proxmox Keyring
RUN wget https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
    -O /usr/share/keyrings/proxmox-archive-keyring.gpg && \
    echo "136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45  /usr/share/keyrings/proxmox-archive-keyring.gpg" | sha256sum -c -

# Proxmox Repo
RUN printf 'Types: deb\nURIs: http://download.proxmox.com/debian/pve\nSuites: trixie\nComponents: pve-no-subscription\nSigned-By: /usr/share/keyrings/proxmox-archive-keyring.gpg\n' \
    > /etc/apt/sources.list.d/pve-install-repo.sources

# Prevent services start
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d

# systemctl stub
RUN mkdir -p /usr/local/sbin && \
    printf '#!/bin/sh\nexit 0\n' > /usr/local/sbin/systemctl && chmod +x /usr/local/sbin/systemctl

# Fix required Proxmox files
RUN mkdir -p /usr/share/doc/pve-manager && touch /usr/share/doc/pve-manager/aplinfo.dat

# Install Proxmox
RUN apt-get update && apt-get full-upgrade -y && \
    apt-get install -y proxmox-ve postfix open-iscsi chrony && \
    apt-get remove -y os-prober || true && \
    rm -rf /var/lib/apt/lists/* /boot /usr/lib/modules /usr/lib/firmware

# Root password
RUN echo 'root:root' | chpasswd

# Cloudflared
RUN wget -O /usr/local/bin/cloudflared \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 && \
    chmod +x /usr/local/bin/cloudflared

# Start script
RUN printf '#!/bin/sh
set -e

echo "[INFO] Starting Proxmox services..."

pvestatd start || true
pvedaemon start || true
pveproxy start || true

echo "[INFO] Waiting for Proxmox API..."
sleep 5

echo "[INFO] Starting Cloudflared tunnel..."

CLOUDFLARED_LOG=/tmp/cloudflared.log

cloudflared tunnel --url http://127.0.0.1:8006 --no-autoupdate > $CLOUDFLARED_LOG 2>&1 &

echo "[INFO] Waiting for tunnel URL..."

while ! grep -oE "https://[a-z0-9-]+\\.trycloudflare.com" $CLOUDFLARED_LOG; do
  sleep 1
done

TUNNEL_URL=$(grep -oE "https://[a-z0-9-]+\\.trycloudflare.com" $CLOUDFLARED_LOG | head -n1)

echo "======================================"
echo " CLOUDFLARED URL: $TUNNEL_URL"
echo " PROXMOX: http://127.0.0.1:8006"
echo "======================================"

tail -f /dev/null
' > /start.sh && chmod +x /start.sh

EXPOSE 8006

CMD ["/start.sh"]
