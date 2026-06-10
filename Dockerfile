FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# -----------------------------
# Base system
# -----------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    systemd \
    systemd-sysv \
    rsyslog \
    wget \
    curl \
    ca-certificates \
    gnupg \
    jq \
    sudo \
    procps \
    net-tools \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------
# Fix syslog socket (PVE requirement)
# -----------------------------
RUN mkdir -p /dev && ln -sf /run/systemd/journal/dev-log /dev/log || true

# -----------------------------
# Proxmox keyring
# -----------------------------
RUN wget https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
    -O /usr/share/keyrings/proxmox-archive-keyring.gpg && \
    echo "136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45  /usr/share/keyrings/proxmox-archive-keyring.gpg" | sha256sum -c -

# -----------------------------
# Proxmox repo
# -----------------------------
RUN printf 'Types: deb\nURIs: http://download.proxmox.com/debian/pve\nSuites: trixie\nComponents: pve-no-subscription\nSigned-By: /usr/share/keyrings/proxmox-archive-keyring.gpg\n' \
    > /etc/apt/sources.list.d/pve-install-repo.sources

# -----------------------------
# Install Proxmox
# -----------------------------
RUN apt-get update && apt-get full-upgrade -y && \
    apt-get install -y proxmox-ve postfix open-iscsi chrony && \
    rm -rf /var/lib/apt/lists/*

# -----------------------------
# Root password
# -----------------------------
RUN echo 'root:root' | chpasswd

# -----------------------------
# Cloudflared
# -----------------------------
RUN wget -O /usr/local/bin/cloudflared \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 && \
    chmod +x /usr/local/bin/cloudflared

# -----------------------------
# Start script (init-based)
# -----------------------------
RUN printf '#!/bin/sh\n\
set -e\n\
\n\
echo "[INFO] Starting systemd (init)..."\n\
\n\
/sbin/init &\n\
sleep 5\n\
\n\
echo "[INFO] Starting rsyslog..."\n\
service rsyslog start || true\n\
\n\
echo "[INFO] Starting Proxmox services..."\n\
pvestatd start || true\n\
pvedaemon start || true\n\
pveproxy start || true\n\
\n\
echo "[INFO] Waiting for API..."\n\
sleep 5\n\
\n\
echo "[INFO] Starting Cloudflared..."\n\
LOG=/tmp/cloudflared.log\n\
cloudflared tunnel --url http://127.0.0.1:8006 --no-autoupdate > $LOG 2>&1 &\n\
\n\
echo "[INFO] Waiting for URL..."\n\
while ! grep -oE "https://[a-z0-9-]+\\.trycloudflare.com" $LOG >/dev/null 2>&1; do\n\
  sleep 1\n\
done\n\
\n\
URL=$(grep -oE "https://[a-z0-9-]+\\.trycloudflare.com" $LOG | head -n1)\n\
\n\
echo "==============================="\n\
echo " CLOUD URL: $URL"\n\
echo " PROXMOX: http://127.0.0.1:8006"\n\
echo "==============================="\n\
\n\
tail -f /dev/null\n' \
> /start.sh && chmod +x /start.sh

EXPOSE 8006

CMD ["/start.sh"]
