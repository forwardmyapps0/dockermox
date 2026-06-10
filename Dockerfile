FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# Install prerequisites
RUN apt-get update && apt-get install -y --no-install-recommends \
      wget \
      ca-certificates \
      curl \
      gnupg \
      lsb-release \
      jq \
      sudo

# Add Proxmox archive keyring
RUN wget https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
      -O /usr/share/keyrings/proxmox-archive-keyring.gpg && \
    echo "136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45  /usr/share/keyrings/proxmox-archive-keyring.gpg" | sha256sum -c -

# Add Proxmox VE no-subscription repository
RUN printf 'Types: deb\nURIs: http://download.proxmox.com/debian/pve\nSuites: trixie\nComponents: pve-no-subscription\nSigned-By: /usr/share/keyrings/proxmox-archive-keyring.gpg\n' \
    > /etc/apt/sources.list.d/pve-install-repo.sources

# Prevent services from starting during install
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d

# Stub commands for Docker
RUN dpkg-divert --local --rename --add /usr/bin/unshare && \
    printf '#!/bin/sh\nwhile [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done\n[ "$1" = "--" ] && shift\n[ $# -gt 0 ] && exec "$@"\nexit 0\n' \
      > /usr/bin/unshare && chmod +x /usr/bin/unshare && \
    dpkg-divert --local --rename --add /usr/sbin/update-initramfs && \
    printf '#!/bin/sh\nexit 0\n' > /usr/sbin/update-initramfs && chmod +x /usr/sbin/update-initramfs && \
    dpkg-divert --local --rename --add /usr/sbin/ifreload && \
    printf '#!/bin/sh\nexit 0\n' > /usr/sbin/ifreload && chmod +x /usr/sbin/ifreload && \
    printf '#!/bin/sh\nexit 0\n' > /usr/local/sbin/systemctl && chmod +x /usr/local/sbin/systemctl

# pve-manager postinst fix
RUN mkdir -p /usr/share/doc/pve-manager && touch /usr/share/doc/pve-manager/aplinfo.dat

# Pin ifupdown2
RUN printf 'Package: ifupdown2\nPin: origin download.proxmox.com\nPin-Priority: 1001\n' \
    > /etc/apt/preferences.d/proxmox-ifupdown2

# Update & install Proxmox VE
RUN apt-get update && \
    apt-get full-upgrade -y && \
    apt-get install -y proxmox-ve postfix open-iscsi chrony && \
    apt-get remove -y os-prober && \
    rm -f /etc/apt/sources.list.d/pve-enterprise.list \
          /etc/apt/sources.list.d/pve-enterprise.sources \
          /etc/apt/sources.list.d/ceph.list \
          /etc/apt/sources.list.d/ceph.sources && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /usr/lib/modules /boot /usr/lib/firmware

# Set root password
RUN echo 'root:root' | chpasswd

# Install Cloudflared
RUN wget -O /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 && \
    chmod +x /usr/local/bin/cloudflared

# Start script (nur einmal ausführen)
RUN printf '#!/bin/sh\n\
echo "[INFO] Starting Proxmox minimal services..."\n\
pvestatd\n\
pvedaemon\n\
pveproxy\n\
echo "[INFO] Waiting for Proxmox API on :8006..."\n\
sleep 5\n\
# Start Cloudflared Tunnel im Hintergrund\n\
CLOUDFLARED_LOG=/tmp/cloudflared.log\n\
echo "[INFO] Starting Cloudflared tunnel..."\n\
cloudflared tunnel --url http://127.0.0.1:8006 --no-autoupdate &> $CLOUDFLARED_LOG &\n\
# URL aus Logs extrahieren\n\
echo "[INFO] Waiting for tunnel URL..."\n\
until grep -oE "https://[a-z0-9-]+\\.trycloudflare.com" $CLOUDFLARED_LOG >/dev/null 2>&1; do sleep 1; done\n\
TUNNEL_URL=$(grep -oE "https://[a-z0-9-]+\\.trycloudflare.com" $CLOUDFLARED_LOG | head -n1)\n\
echo "======================================"\n\
echo " CLOUDFLARED URL: $TUNNEL_URL"\n\
echo " PROXMOX: http://127.0.0.1:8006"\n\
echo "======================================"\n\
# Container dauerhaft am Leben halten\n\
tail -f /dev/null\n' \
> /start.sh && chmod +x /start.sh

EXPOSE 8006

CMD ["/start.sh"]
