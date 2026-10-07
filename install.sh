#!/bin/bash
# Rhizome: "ssh <machine>@ssh.example.com" reaches a machine at home through a small VPS.
#
# Run as root on the home server:
#   bash <(curl -fsSL https://raw.githubusercontent.com/Ivy-js/rhizome/main/install.sh) root@VPS_IP --domain ssh.example.com
#
# Sets up both sides; run it again to update (previous options are kept).
#   --domain <name>      name given to users (DNS A record to the VPS, not proxied)
#   --network <a.b.c>    network of the published machines (default 192.168.10)
#   --first <n>          first published host (default 2)
#   --last <n>           last published host (default 249)
#   --port <n>           current SSH port of the VPS (default 22)
#   --admin-port <n>     SSH admin port of the VPS once installed (default 4022)
set -euo pipefail

REPO=${RHIZOME_REPO:-https://github.com/Ivy-js/rhizome}
BRANCH=${RHIZOME_BRANCH:-main}
DIR=/etc/rhizome

title() { printf '\n\033[1;32m>>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mrhizome:\033[0m %s\n' "$*" >&2; exit 1; }
number() { [[ $2 =~ ^[0-9]{1,5}$ ]] || die "$1: number expected ($2)"; }

main() {
    local VPS="" DOMAIN="" NETWORK=192.168.10 FIRST=2 LAST=249 ADMIN_PORT=4022 PORT_BASE=22000
    # shellcheck source=/dev/null
    [ -f "$DIR/rhizome.conf" ] && . "$DIR/rhizome.conf"
    local target="" port=22
    while [ $# -gt 0 ]; do
        case "$1" in
            --domain) DOMAIN=${2:?}; shift 2 ;;
            --network) NETWORK=${2:?}; shift 2 ;;
            --first) FIRST=${2:?}; shift 2 ;;
            --last) LAST=${2:?}; shift 2 ;;
            --port) port=${2:?}; shift 2 ;;
            --admin-port) ADMIN_PORT=${2:?}; shift 2 ;;
            -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
            -*) die "unknown option: $1" ;;
            *) target=$1; shift ;;
        esac
    done
    if [ -z "$target" ] && [ -n "$VPS" ]; then
        target=root@$VPS
    fi
    [[ $target == root@?* ]] || die "usage: install.sh root@VPS_IP [--domain ssh.example.com]"
    VPS=${target#root@}
    DOMAIN=${DOMAIN:-$VPS}
    [[ $NETWORK =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || die "network must look like 192.168.10"
    number --first "$FIRST"; number --last "$LAST"; number --port "$port"; number --admin-port "$ADMIN_PORT"
    ((FIRST >= 1 && FIRST <= LAST && LAST <= 254)) || die "invalid range: $FIRST-$LAST"
    ((ADMIN_PORT != 22)) || die "port 22 of the VPS is reserved for the relay"
    [ "$(id -u)" = 0 ] || die "must run as root"
    local c
    for c in ssh ssh-keygen tar systemctl runuser; do
        command -v "$c" >/dev/null || die "$c is required"
    done

    TMP=$(mktemp -d)
    trap 'ssh -O exit -o ControlPath="$TMP/master" x >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

    # Use the files next to this script (cloned repo), otherwise download the repo archive
    local src here
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)
    if [ -f "$here/vps/setup.sh" ] && [ -f "$here/home/rhizome" ]; then
        src=$here
    else
        src=$TMP/src
        mkdir -p "$src"
        local archive=$REPO/archive/refs/heads/$BRANCH.tar.gz
        if command -v curl >/dev/null; then
            curl -fsSL "$archive" | tar -xzf - -C "$src" --strip-components=1
        else
            wget -qO- "$archive" | tar -xzf - -C "$src" --strip-components=1
        fi
        [ -f "$src/vps/setup.sh" ] || die "incomplete archive: $archive"
    fi

    title "Home: account and keys"
    getent group rhizome >/dev/null || groupadd --system rhizome
    id rhizome >/dev/null 2>&1 || useradd --system --gid rhizome --home-dir /nonexistent \
        --shell /usr/sbin/nologin rhizome
    install -d -m 0755 -o root -g rhizome "$DIR"
    [ -f "$DIR/key" ] || ssh-keygen -q -t ed25519 -N '' -C "rhizome@$(hostname)" -f "$DIR/key"
    # Group-readable: used by the tunnel and by route publishers (e.g. Sprout)
    chown root:rhizome "$DIR/key"
    chmod 0640 "$DIR/key"
    local admin=""
    for c in /root/.ssh/id_ed25519 /root/.ssh/id_ecdsa /root/.ssh/id_rsa; do
        [ -f "$c" ] && [ -f "$c.pub" ] && { admin=$c; break; }
    done
    if [ -z "$admin" ]; then
        admin=/root/.ssh/id_ed25519
        install -d -m 0700 /root/.ssh
        ssh-keygen -q -t ed25519 -N '' -C "root@$(hostname)" -f "$admin"
    fi
    echo "   tunnel key: $DIR/key · VPS admin key: $admin"

    title "VPS: connecting to $VPS"
    local -a ssh_vps=(ssh -o ControlMaster=auto -o ControlPath="$TMP/master" -o ControlPersist=600
        -o UserKnownHostsFile="$DIR/known_hosts_admin" -o StrictHostKeyChecking=accept-new
        -i "$admin" -o ServerAliveInterval=15)
    local port_used
    if "${ssh_vps[@]}" -o BatchMode=yes -o ConnectTimeout=8 -p "$ADMIN_PORT" "$target" true </dev/null 2>/dev/null; then
        port_used=$ADMIN_PORT
    else
        echo "   (the VPS root password is asked if it does not have this server's key yet)"
        "${ssh_vps[@]}" -o ConnectTimeout=15 -p "$port" "$target" true </dev/null \
            || die "cannot connect to root@$VPS on port $port"
        port_used=$port
    fi
    on_vps() { "${ssh_vps[@]}" -p "$port_used" "$target" "$@"; }

    title "VPS: installing the relay"
    tar -C "$src" -czf - vps | on_vps 'rm -rf /root/rhizome && mkdir -p /root/rhizome && tar -xzf - -C /root/rhizome'
    on_vps "bash /root/rhizome/vps/setup.sh '$(cat "$DIR/key.pub")' '$(cat "$admin.pub")' $ADMIN_PORT" </dev/null \
        || die "VPS setup failed (see above)"
    # Pin the VPS host key, read over the already authenticated connection
    local host_key
    host_key=$(on_vps 'cat /etc/ssh/ssh_host_ed25519_key.pub' </dev/null | awk '{ print $1, $2 }')
    [ -n "$host_key" ] || die "VPS host key not found"
    echo "rhizome-vps $host_key" > "$DIR/known_hosts"
    chmod 0644 "$DIR/known_hosts"
    # A fresh key login on the admin port cancels the VPS automatic rollback
    ssh -o ControlPath=none -o BatchMode=yes -o ConnectTimeout=15 -o HostKeyAlias=rhizome-vps \
        -o UserKnownHostsFile="$DIR/known_hosts" -o StrictHostKeyChecking=yes -i "$admin" \
        -p "$ADMIN_PORT" "root@$VPS" 'systemctl stop rhizome-rollback.timer >/dev/null 2>&1; true' </dev/null \
        || die "no access on port $ADMIN_PORT: the VPS restores its previous SSH config within 3 minutes"
    echo "   admin access confirmed on port $ADMIN_PORT"

    title "Home: tunnel"
    cat > "$DIR/rhizome.conf" <<EOF
# Written by install.sh (run 'rhizome configure' after editing)
VPS=$VPS
ADMIN_PORT=$ADMIN_PORT
DOMAIN=$DOMAIN
# $NETWORK.N (N = FIRST..LAST) is published on 127.0.0.1:PORT_BASE+N of the VPS
NETWORK=$NETWORK
FIRST=$FIRST
LAST=$LAST
PORT_BASE=$PORT_BASE
EOF
    chmod 0644 "$DIR/rhizome.conf"
    install -m 0755 "$src/home/rhizome" /usr/local/bin/rhizome
    install -m 0644 "$src/home/rhizome-tunnel.service" /etc/systemd/system/rhizome-tunnel.service
    systemctl daemon-reload
    rhizome configure
    systemctl enable --quiet rhizome-tunnel
    systemctl restart rhizome-tunnel
    local expected=$((LAST - FIRST + 1)) open=0 i
    for i in $(seq 1 20); do
        open=$(on_vps 'ss -ltn' </dev/null | awk -v a=$((PORT_BASE + FIRST)) -v b=$((PORT_BASE + LAST)) \
            '{ n = split($4, p, ":"); if (p[1] == "127.0.0.1" && p[n] >= a && p[n] <= b) c++ } END { print c + 0 }')
        [ "$open" -ge "$expected" ] && break
        sleep 2
    done
    [ "$open" -ge "$expected" ] || die "tunnel incomplete ($open / $expected ports): journalctl -u rhizome-tunnel"
    echo "   $open ports open on the VPS"

    if id sprout >/dev/null 2>&1 && [ -d /opt/sprout ]; then
        title "Sprout"
        usermod -aG rhizome sprout
        systemctl try-restart sprout
        echo "   Sprout publishes its machines through Rhizome"
    fi

    title "Rhizome is ready"
    rhizome status
    cat <<EOF

  Once, at your DNS provider:
    A  $DOMAIN  →  $VPS   (not proxied: grey cloud on Cloudflare)

  Publish a machine:   rhizome add vm-lucas $NETWORK.$FIRST lucas
  Users then run:      ssh vm-lucas@$DOMAIN
  Manage the VPS:      rhizome vps   (sshd now listens on port $ADMIN_PORT)
EOF
}

main "$@"
