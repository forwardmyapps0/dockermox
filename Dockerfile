FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# Basis Tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    curl \
    gnupg \
    ca-certificates \
    sudo \
    tar \
    lsb-release \
    procps \
    iproute2 \
    systemd \
    && rm -rf /var/lib/apt/lists/*

# Proxmox Keyring
RUN wget https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
      -O /usr/share/keyrings/proxmox-archive-keyring.gpg && \
    echo "136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45  /usr/share/keyrings/proxmox-archive-keyring.gpg" \
    | sha256sum -c -

# Proxmox Repo
RUN printf 'Types: deb\nURIs: http://download.proxmox.com/debian/pve\nSuites: trixie\nComponents: pve-no-subscription\nSigned-By: /usr/share/keyrings/proxmox-archive-keyring.gpg\n' \
    > /etc/apt/sources.list.d/pve-install-repo.sources

# Install Proxmox
RUN apt-get update && apt-get full-upgrade -y && \
    apt-get install -y \
      proxmox-ve \
      postfix \
      open-iscsi \
      chrony && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Root Passwort (nur für Test!)
RUN echo 'root:root' | chpasswd

# Cloudflared installieren
RUN curl -L -o /usr/local/bin/cloudflared \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 && \
    chmod +x /usr/local/bin/cloudflared

# Startscript
RUN cat > /usr/local/bin/start.sh <<'EOF' && chmod +x /usr/local/bin/start.sh
#!/bin/sh

echo "======================================"
echo "Starting Proxmox + Cloudflared"
echo "======================================"

# Cloudflared nur einmal starten
if ! pgrep cloudflared > /dev/null; then
    cloudflared tunnel --url http://127.0.0.1:8006 > /tmp/cloudflared.log 2>&1 &
fi

# Warte auf URL
echo "Waiting for Cloudflare tunnel..."
for i in $(seq 1 60); do
    URL=$(grep -o 'https://[-a-zA-Z0-9]*\.trycloudflare\.com' /tmp/cloudflared.log | head -n1)
    if [ -n "$URL" ]; then
        echo "======================================"
        echo "Cloudflare Tunnel URL:"
        echo "$URL"
        echo "======================================"
        break
    fi
    sleep 1
done

# Proxmox Dienste starten (nur wenn nötig)
for svc in pvedaemon pveproxy pvestatd; do
    service $svc start 2>/dev/null
done

echo "System running..."

# Container am Leben halten
tail -f /dev/null
EOF

EXPOSE 8006

CMD ["/usr/local/bin/start.sh"]
