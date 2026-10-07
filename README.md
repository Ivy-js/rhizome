<p align="center">
  <img src="assets/logo.png" alt="Rhizome" width="440">
</p>

Reach a machine at home with a plain `ssh <machine>@ssh.example.com`, from any SSH client
(scp, SFTP and VS Code included), through a small VPS. Nothing to open on the router,
nothing to install for users.

```
user ── ssh vm-lucas@ssh.example.com ──▶ VPS :22, sshpiper follows the "vm-lucas" route
                                           │
                                           ▼ reverse SSH tunnel opened by the home server
                                         lucas@192.168.10.2:22
```

## Install

As root on the home server (Proxmox, Debian, Ubuntu), with a VPS that has a public IPv4
(Debian or Ubuntu; a tiny OpenVZ container without TUN is fine):

```
bash <(curl -fsSL https://raw.githubusercontent.com/Ivy-js/rhizome/main/install.sh) root@VPS_IP --domain ssh.example.com
```

It configures both sides: connects to the VPS (asks for its root password once if needed),
installs the relay there, then opens the tunnel from home. Run it again to update.

Then add a DNS record `A ssh.example.com → VPS_IP`, **not proxied** (SSH does not go through
Cloudflare's proxy).

Options: `--network 192.168.10`, `--first 2`, `--last 249` (published machines),
`--port 22` (current VPS SSH port), `--admin-port 4022`.

## Usage

```
rhizome status                              tunnel, relay, fingerprint and routes
rhizome add vm-lucas 192.168.10.2 lucas     ssh vm-lucas@ssh.example.com → lucas@192.168.10.2
rhizome remove vm-lucas
rhizome routes
rhizome publish < routes.txt                replace all routes ("name ip user" per line)
rhizome vps                                 root shell on the VPS
```

Sprout publishes its machines automatically with `rhizome publish`, which replaces the whole
table: routes added by hand are dropped on the next change in Sprout.

## Security

- The VPS has no access to the home network: the home server connects to it with an account
  that can only hold the tunnel and manage routes (forced command, no TTY, no local forwarding).
- The tunnel only reaches port 22 of published machines, on VPS loopback ports.
- Machines see connections coming from the home server, never the user's address.
- 5 wrong passwords from an IP get it banned for an hour.
- VPS admin SSH moves to port 4022, keys only. If setup breaks access, the VPS restores its
  previous SSH config after 3 minutes.
- sshpiper decrypts and re-encrypts sessions: keep the VPS updated and to yourself.
- The sshpiper release is checked against a SHA-256 pinned in `vps/setup.sh`.

## Layout

- `install.sh` — one-line install, run at home
- `home/rhizome` — CLI; `home/rhizome-tunnel.service` — the tunnel
- `vps/setup.sh` — relay setup: sshpiper on port 22, accounts, sshd on the admin port
- `vps/rhizome-routes` — forced command: routes → sshpiper table
- `vps/rhizome-piper.service`, `vps/sshd_config`

Installed files: `/etc/rhizome` at home; `/usr/local/lib/rhizome`, `/var/lib/rhizome` and
`/etc/rhizome` on the VPS.
