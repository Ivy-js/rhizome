#!/bin/bash
# VPS side of Rhizome, run as root by install.sh:
#   setup.sh "<tunnel public key>" "<admin public key>" <admin port>
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TUNNEL_KEY=${1:-}
ADMIN_KEY=${2:-}
ADMIN_PORT=${3:-4022}
VERSION=v1.6.1
declare -A SHA256=(
    [x86_64]=95d423a70e843a7512a72fbb16c0fa5dc59217cf064cb3e277520fddffded1e1
    [arm64]=ceb92a4b91e8d163c3dafc3d40bc678a32046f076a557ea5b83ff573cf932c6f
)
BIN=/usr/local/lib/rhizome
DATA=/var/lib/rhizome

step() { echo "   · $*"; }

for key in "$TUNNEL_KEY" "$ADMIN_KEY"; do
    case "$key" in
        ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*) ;;
        *) echo "usage: $0 \"<tunnel key>\" \"<admin key>\" <admin port>"; exit 1 ;;
    esac
done
case "$ADMIN_PORT" in ''|*[!0-9]*|22) echo "invalid admin port: $ADMIN_PORT"; exit 1 ;; esac
case "$(uname -m)" in
    x86_64) arch=x86_64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "unsupported architecture: $(uname -m)"; exit 1 ;;
esac

step "disabling services shipped with the provider image"
for service in apache2 rpcbind.socket rpcbind; do
    systemctl disable --now "$service" >/dev/null 2>&1 || true
done

step "sshpiper $VERSION ($arch)"
if [ "$(cat "$BIN/VERSION" 2>/dev/null)" != "$VERSION" ]; then
    tmp=$(mktemp -d)
    url=https://github.com/tg123/sshpiper/releases/download/$VERSION/sshpiperd_with_plugins_linux_$arch.tar.gz
    if command -v curl >/dev/null; then curl -fsSL -o "$tmp/sshpiper.tar.gz" "$url"
    else wget -q -O "$tmp/sshpiper.tar.gz" "$url"; fi
    if [ "$(sha256sum "$tmp/sshpiper.tar.gz" | cut -d' ' -f1)" != "${SHA256[$arch]}" ]; then
        rm -rf "$tmp"
        echo "     ! checksum mismatch"
        exit 1
    fi
    tar -xzf "$tmp/sshpiper.tar.gz" -C "$tmp"
    install -d "$BIN/plugins"
    install -m 0755 "$tmp/sshpiperd" "$BIN/"
    install -m 0755 "$tmp/plugins/yaml" "$tmp/plugins/failtoban" "$BIN/plugins/"
    echo "$VERSION" > "$BIN/VERSION"
    rm -rf "$tmp"
fi

step "accounts rhizome-piper (relay) and rhizome (home server)"
id rhizome-piper >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent \
    --shell /usr/sbin/nologin rhizome-piper
# sshd needs a real shell to run the forced command
id rhizome >/dev/null 2>&1 || useradd --system --home-dir "$DATA" --shell /bin/sh rhizome
install -d -m 0755 -o rhizome -g rhizome "$DATA"
install -d -m 0700 -o rhizome -g rhizome "$DATA/.ssh"
echo "restrict,port-forwarding $TUNNEL_KEY" > "$DATA/.ssh/authorized_keys"
chown rhizome:rhizome "$DATA/.ssh/authorized_keys"
chmod 0600 "$DATA/.ssh/authorized_keys"
install -d -m 2750 -o rhizome -g rhizome-piper "$DATA/table"
if [ ! -f "$DATA/table/pipes.yaml" ]; then
    printf 'version: "1.0"\npipes: []\n' > "$DATA/table/pipes.yaml"
    chown rhizome:rhizome-piper "$DATA/table/pipes.yaml"
    chmod 0640 "$DATA/table/pipes.yaml"
fi
install -m 0755 "$HERE/rhizome-routes" /usr/local/sbin/rhizome-routes

step "relay host key (the fingerprint users accept, same for every machine)"
install -d -m 0755 /etc/rhizome
[ -f /etc/rhizome/host_key ] || ssh-keygen -q -t ed25519 -N '' -C rhizome -f /etc/rhizome/host_key
chown rhizome-piper:rhizome-piper /etc/rhizome/host_key
chmod 0600 /etc/rhizome/host_key
chmod 0644 /etc/rhizome/host_key.pub

step "home server admin key for root"
install -d -m 0700 /root/.ssh
touch /root/.ssh/authorized_keys
grep -qF "$(echo "$ADMIN_KEY" | awk '{ print $2 }')" /root/.ssh/authorized_keys \
    || echo "$ADMIN_KEY" >> /root/.ssh/authorized_keys
chmod 0600 /root/.ssh/authorized_keys

step "sshd: admin on port $ADMIN_PORT, keys only"
[ -f /etc/ssh/sshd_config.orig ] || cp /etc/ssh/sshd_config /etc/ssh/sshd_config.orig
sed "s/@ADMIN_PORT@/$ADMIN_PORT/g" "$HERE/sshd_config" > /etc/ssh/sshd_config.rhizome
sshd -t -f /etc/ssh/sshd_config.rhizome
if ! cmp -s /etc/ssh/sshd_config.rhizome /etc/ssh/sshd_config; then
    # Rolls back in 3 minutes unless install.sh confirms it can still log in
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.rhizome-prev
    systemctl stop rhizome-rollback.timer >/dev/null 2>&1 || true
    systemctl reset-failed rhizome-rollback.service >/dev/null 2>&1 || true
    systemd-run --quiet --unit=rhizome-rollback --on-active=180 /bin/sh -c \
        'cp /etc/ssh/sshd_config.rhizome-prev /etc/ssh/sshd_config; systemctl disable --now rhizome-piper; systemctl restart ssh'
    mv /etc/ssh/sshd_config.rhizome /etc/ssh/sshd_config
    # Recent Ubuntu starts sshd from a socket that ignores the configured port
    systemctl disable --now ssh.socket >/dev/null 2>&1 || true
    systemctl enable --quiet ssh
    systemctl restart ssh
    step "automatic rollback in 3 minutes unless confirmed"
else
    rm -f /etc/ssh/sshd_config.rhizome
fi

step "relay on port 22"
install -m 0644 "$HERE/rhizome-piper.service" /etc/systemd/system/rhizome-piper.service
systemctl daemon-reload
systemctl enable --quiet rhizome-piper
systemctl restart rhizome-piper
sleep 2
systemctl is-active --quiet rhizome-piper || { journalctl -u rhizome-piper -n 20 --no-pager; exit 1; }
