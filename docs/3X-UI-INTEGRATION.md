# Optional 3x-ui user management (Level 1)

This guide is **separate** from the core XHTTP-Installer. It does not modify `Deploy-Ubuntu.sh`, `install.sh`, or the `xhttp` CLI.

Use it when you want **multiple users**, **traffic limits** (e.g. 10 GB), and expiry — via [3x-ui](https://github.com/MHSanaei/3x-ui) on the same VPS.

---

## Architecture

```text
Client → CDN (Vercel/Netlify) → Xray on VPS (managed by 3x-ui) → Internet
Admin  → 3x-ui web panel (separate port, e.g. 2053)
```

- **Unchanged:** CDN relay, `TARGET_DOMAIN`, paths, Vercel/Netlify env vars.
- **Handoff:** Installer `xray` systemd service is stopped/disabled; **3x-ui** runs Xray on port `443` (or your inbound port).

---

## Prerequisites

1. Successful XHTTP-Installer run on Ubuntu.
2. File exists: `/etc/xhttp-installer/info.env` (created by the installer).
3. Root access on the server.
4. Repo cloned on the server (e.g. `/root/XHTTP-Installer`) **or** copy `scripts/integrate-3xui.sh` manually.

---

## Quick start

### Step 1 — Generate checklist (and optional 3x-ui install)

```bash
cd /root/XHTTP-Installer
sudo bash scripts/integrate-3xui.sh --install --install-bin
```

| Flag | Purpose |
|------|---------|
| `--install` | Runs official 3x-ui `install.sh` (interactive) |
| `--install-bin` | Copies script to `/usr/local/bin/xhttp-3xui` |
| *(no flags)* | Backup + checklist only |
| `--finalize` | Only stop/disable installer `xray` (after inbound exists in 3x-ui) |

Outputs:

- `/etc/xhttp-installer/3xui-checklist.txt` — full field list
- `/etc/xhttp-installer/xray-config.before-3xui.*.json` — backup
- `/etc/xhttp-installer/3xui.env` — integration state

### Step 2 — Configure inbound in 3x-ui

Open the 3x-ui panel URL from the 3x-ui installer output.

**Panel rules:**

- Panel port must **not** be `443` (use e.g. `2053`).
- Prefer **HTTP on high port + SSH tunnel** or **custom TLS** using existing cert paths — avoid re-issuing LE on port 80 while debugging.

Create **one inbound** using the checklist. Critical split:

| Setting | Value source (`info.env`) |
|---------|---------------------------|
| XHTTP **host** (server) | `CFG_DOMAIN` |
| **External proxy** / client address, SNI, Host | `VERCEL_HOST` |
| XHTTP **path** | `CFG_RELAY_PATH` |
| Client **path** | `CFG_PUBLIC_PATH` |
| TLS cert/key | `SSL_CERT`, `SSL_KEY` |
| Port | `CFG_INBOUND_PORT` (usually `443`) |

### Step 3 — Add users

In 3x-ui → inbound → add clients:

- **Total traffic:** e.g. `10` GB
- **Expiry:** optional
- Copy **QR / link** per user

Verify each link uses **`VERCEL_HOST`** (CDN), not only `CFG_DOMAIN`.

### Step 4 — Finalize handoff

After the inbound works in 3x-ui:

```bash
sudo xhttp-3xui --finalize
```

Or re-run and confirm when prompted. This **stops and disables** the installer `xray` service so only 3x-ui owns the proxy port.

---

## Field mapping reference

| `info.env` variable | 3x-ui / client usage |
|---------------------|----------------------|
| `CFG_DOMAIN` | XHTTP `host` on **server** inbound |
| `VERCEL_HOST` | External proxy `dest`; client Address, SNI, Request Host |
| `CFG_RELAY_PATH` | Server XHTTP path |
| `CFG_PUBLIC_PATH` | Client path (often same as relay path) |
| `CFG_INBOUND_PORT` | Listen port (usually `443`) |
| `SSL_CERT` / `SSL_KEY` | TLS certificate files |
| `XPADDING`, `XPADDING_KEY`, `XPADDING_HEADER`, `SC_MAX_POST_BYTES` | **Netlify only** — inbound + client `extra` JSON |
| `INBOUND_UUID` | Optional first client UUID |
| `CLIENT_LINK` | Reference — compare after panel generates links |
| `CFG_PLATFORM` | `vercel` or `netlify` — padding rules differ |

### Vercel vs Netlify padding

| Platform | Server / client `extra` |
|----------|-------------------------|
| **Vercel** | `xPaddingBytes`: `100-1000` |
| **Netlify** | `xPaddingBytes`: `10-50`, `xPaddingObfsMode`: true, plus `xPaddingKey`, `xPaddingHeader`, `scMaxEachPostBytes` |

Mismatch breaks connections after migration.

---

## Per-user limits (10 GB example)

1. 3x-ui → select inbound → **Add client**
2. Set **Total GB** = `10`
3. Set **Reset** cycle if offered (monthly)
4. Enable/disable per user as needed

Limits are enforced by 3x-ui (stats + DB), not by XHTTP-Installer.

---

## Panel security

- Do not expose the 3x-ui panel to the whole internet without a strong password.
- Prefer: random high port + `ufw allow from YOUR_IP to any port PANEL_PORT`
- Or: bind panel to `127.0.0.1` and use SSH port forwarding (see 3x-ui install SSL option 4).

---

## Rollback (restore installer-only proxy)

If integration fails, restore the backed-up config:

```bash
systemctl stop x-ui
systemctl disable x-ui

# Use the path from 3xui.env or the newest backup in /etc/xhttp-installer/
cp /etc/xhttp-installer/xray-config.before-3xui.YYYYMMDDHHMMSS.json \
   /usr/local/etc/xray/config.json

systemctl enable xray
systemctl start xray
```

Test with the original `vless://` link from `xhttp` or `CLIENT_LINK` in `info.env`.

To remove 3x-ui completely: `x-ui uninstall` (see 3x-ui docs).

---

## Troubleshooting

### Port 443 already in use

- Cause: both `xray` and `x-ui` trying to bind `443`.
- Fix: run `--finalize` only after 3x-ui inbound is created; `systemctl stop xray`.

### Client connects but no traffic / TLS errors

- **Wrong host in link:** client must use `VERCEL_HOST`, not `CFG_DOMAIN`.
- **External proxy** not set in 3x-ui inbound.
- **Path mismatch:** `CFG_PUBLIC_PATH` on client vs `CFG_RELAY_PATH` on server.

### Netlify works before 3x-ui, fails after

- Re-enter **all** obfs fields from checklist (`XPADDING_KEY`, `XPADDING_HEADER`, etc.).
- Compare new link `extra` param to `CLIENT_LINK` in `info.env`.

### Subscription URL returns 500 (XHTTP)

Some 3x-ui versions have subscription bugs for XHTTP. Use **per-client QR/link** from the panel instead.

### Vercel usage / relay broken

- Do **not** change Vercel project env (`TARGET_DOMAIN`, `RELAY_PATH`, `PUBLIC_RELAY_PATH`).
- CDN layer is independent of 3x-ui.

### `info.env` missing

Run XHTTP-Installer first (`bash install.sh` or `Deploy-Ubuntu.sh`).

---

## Script reference

```bash
sudo bash /root/XHTTP-Installer/scripts/integrate-3xui.sh --help
sudo xhttp-3xui --help   # after --install-bin
```

| File | Purpose |
|------|---------|
| `scripts/integrate-3xui.sh` | Integration helper (this repo) |
| `/etc/xhttp-installer/info.env` | Written by XHTTP-Installer |
| `/etc/xhttp-installer/3xui-checklist.txt` | Generated checklist |
| `/etc/xhttp-installer/3xui.env` | Integration run metadata |

---

## What is not included (Level 2)

- Automatic inbound creation via 3x-ui API
- Changes to `Deploy-Ubuntu.sh` or `xhttp` menu
- Vendored 3x-ui source code

---

## License note

3x-ui is GPL-3.0. XHTTP-Installer is GPL-3.0. This integration script only **invokes** the official 3x-ui installer URL; it does not bundle 3x-ui code.
