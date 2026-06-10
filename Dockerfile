FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# Install prerequisites
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    curl \
    gnupg \
    ca-certificates \
    sudo \
    tar \
    lsb-release

# Add Proxmox archive keyring
RUN wget https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
      -O /usr/share/keyrings/proxmox-archive-keyring.gpg && \
    echo "136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45  /usr/share/keyrings/proxmox-archive-keyring.gpg" | sha256sum -c -

# Add Proxmox VE no-subscription repository
RUN printf 'Types: deb\nURIs: http://download.proxmox.com/debian/pve\nSuites: trixie\nComponents: pve-no-subscription\nSigned-By: /usr/share/keyrings/proxmox-archive-keyring.gpg\n' \
    > /etc/apt/sources.list.d/pve-install-repo.sources

# Prevent services from starting during install
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d

# Stub commands unavailable/problematic in Docker build
RUN dpkg-divert --local --rename --add /usr/bin/unshare && \
    printf '#!/bin/sh\nwhile [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done\n[ "$1" = "--" ] && shift\n[ $# -gt 0 ] && exec "$@"\nexit 0\n' \
      > /usr/bin/unshare && chmod +x /usr/bin/unshare && \
    dpkg-divert --local --rename --add /usr/sbin/update-initramfs && \
    printf '#!/bin/sh\nexit 0\n' > /usr/sbin/update-initramfs && chmod +x /usr/sbin/update-initramfs && \
    dpkg-divert --local --rename --add /usr/sbin/ifreload && \
    printf '#!/bin/sh\nexit 0\n' > /usr/sbin/ifreload && chmod +x /usr/sbin/ifreload && \
    printf '#!/bin/sh\nexit 0\n' > /usr/local/sbin/systemctl && chmod +x /usr/local/sbin/systemctl

# pve-manager postinst copies this file
RUN mkdir -p /usr/share/doc/pve-manager && touch /usr/share/doc/pve-manager/aplinfo.dat

# Pin ifupdown2 to Proxmox repo
RUN printf 'Package: ifupdown2\nPin: origin download.proxmox.com\nPin-Priority: 1001\n' \
    > /etc/apt/preferences.d/proxmox-ifupdown2

# Update system and install Proxmox VE
RUN apt-get update && \
    apt-get full-upgrade -y && \
    apt-get install -y \
      proxmox-ve \
      postfix \
      open-iscsi \
      chrony && \
    apt-get remove -y os-prober && \
    rm -f /etc/apt/sources.list.d/pve-enterprise.list \
          /etc/apt/sources.list.d/pve-enterprise.sources \
          /etc/apt/sources.list.d/ceph.list \
          /etc/apt/sources.list.d/ceph.sources && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /usr/lib/modules /boot /usr/lib/firmware \
           /usr/share/doc /usr/share/man

# Root password
RUN echo 'root:root' | chpasswd

# Install cloudflared
RUN curl -L -o /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 && \
    chmod +x /usr/local/bin/cloudflared

# Startup script for cloudflared + Proxmox
RUN cat > /usr/local/bin/start.sh <<'EOF' && chmod +x /usr/local/bin/start.sh
#!/bin/sh

echo "======================================"
echo "Starting Proxmox VE..."
echo "======================================"

# Start cloudflared tunnel in background
cloudflared tunnel --url http://127.0.0.1:8006 > /tmp/cloudflared.log 2>&1 &

echo "Waiting for Cloudflare tunnel..."

for i in $(seq 1 60); do
    URL=$(grep -o 'https://[-a-zA-Z0-9]*\.trycloudflare\.com' /tmp/cloudflared.log | head -n1)
    if [ -n "$URL" ]; then
        echo ""
        echo "======================================"
        echo "Cloudflare Tunnel URL:"
        echo "$URL"
        echo "======================================"
        echo ""
        break
    fi
    sleep 1
done

exec /sbin/init
EOF

EXPOSE 8006

CMD ["/usr/local/bin/start.sh"]
