---
name: 3x-ui Level 1 Integration
overview: Add a standalone integration script and light wiring in XHTTP-Installer so operators can install 3x-ui on the same VPS, safely hand off from installer-managed `xray`, and configure the panel using values from `/etc/xhttp-installer/info.env`—without vendoring 3x-ui or automating its API (Level 2).
todos:
  - id: script-integrate-3xui
    content: Create scripts/integrate-3xui.sh with backup, checklist generation, flags (--install, --finalize), and 3xui.env state
    status: pending
  - id: deploy-copy-binary
    content: Update phase7_install_panel to install /usr/local/bin/xhttp-3xui from SCRIPT_DIR
    status: pending
  - id: xhttp-menu-prompt
    content: Add xhttp menu item 8, phase6_summary line, optional post-install prompt in main()
    status: pending
  - id: docs-3xui
    content: Add docs/3X-UI-INTEGRATION.md and README_EN/README.md sections with rollback and troubleshooting
    status: pending
isProject: false
---

# Level 1: 3x-ui integration plan

## Goal

Enable **multi-user management via 3x-ui** after a successful XHTTP-Installer run, with:

- No 3x-ui source code in the repo
- No API/automated inbound creation (that is Level 2)
- Clear, copy-paste inbound checklist derived from [`Deploy-Ubuntu.sh`](Deploy-Ubuntu.sh) / [`info.env`](Deploy-Ubuntu.sh) (written in `phase7_install_panel`)

## Architecture

```mermaid
flowchart TB
    subgraph installer [XHTTP-Installer]
        Deploy[Deploy-Ubuntu.sh]
        State[info.env]
        XhttpCLI[xhttp CLI]
    end
    subgraph level1 [New Level 1]
        Script[scripts/integrate-3xui.sh]
        Bin[/usr/local/bin/xhttp-3xui]
        Guide[docs/3X-UI-INTEGRATION.md]
    end
    subgraph external [External]
        ThreeXUI[3x-ui install.sh]
        Panel[3x-ui Web UI]
        XuiXray[Xray via x-ui service]
    end
    Deploy --> State
    Deploy --> Bin
    Script --> Bin
    XhttpCLI --> Script
    Script --> State
    Script -->|"optional"| ThreeXUI
    ThreeXUI --> Panel
    Panel --> XuiXray
    Users --> CDN[Vercel/Netlify relay unchanged]
    CDN --> XuiXray
```

**Unchanged:** Vercel/Netlify relay, `TARGET_DOMAIN`, paths, SSL on server at `/etc/ssl/xhttp/...`.

**Handoff:** Stop/disable systemd service **`xray`** (installer) so **`x-ui`** can own port `CFG_INBOUND_PORT` (usually 443).

---

## Deliverables

### 1. New script: [`scripts/integrate-3xui.sh`](scripts/integrate-3xui.sh)

Standalone bash script (root-only), `set -euo pipefail`, reusing the installer’s tone (info/ok/warn/fail helpers inlined or minimal).

** Preconditions**

- `/etc/xhttp-installer/info.env` exists (from [`phase7_install_panel`](Deploy-Ubuntu.sh) ~L2657)
- `systemctl` available

**Flags (keep Level 1 simple)**

| Flag | Behavior |
|------|----------|
| *(default)* | Backup + print checklist + optional steps |
| `--install` | Also launch official `bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)` (interactive; document that user completes panel port/credentials) |
| `--finalize` | Skip 3x-ui install; only backup + `stop`/`disable` `xray` + post-checklist (for users who already installed 3x-ui) |
| `--help` | Usage |

**Steps (core flow)**

1. **Source** `info.env` (same variables as today: `CFG_DOMAIN`, `CFG_INBOUND_PORT`, `CFG_RELAY_PATH`, `CFG_PUBLIC_PATH`, `VERCEL_HOST`, `SSL_CERT`, `SSL_KEY`, `XPADDING*`, `CFG_PLATFORM`, `INBOUND_UUID`).
2. **Backup** `/usr/local/etc/xray/config.json` → `/etc/xhttp-installer/xray-config.before-3xui.json` (timestamped copy if file exists).
3. **Print checklist** to terminal and write **`/etc/xhttp-installer/3xui-checklist.txt`** (mode 600) with two sections:
   - **3x-ui inbound (server):** VLESS, XHTTP, TLS, port, cert paths, path=`CFG_RELAY_PATH`, XHTTP host=`CFG_DOMAIN`, mode=auto, padding fields (Vercel vs Netlify branch matching [`phase4b_configure_xray`](Deploy-Ubuntu.sh) L975–997).
   - **Client / external proxy (CDN):** Address, SNI, Request Host = `VERCEL_HOST`; path = `CFG_PUBLIC_PATH`; note subscription/subHost if applicable.
   - **First client:** optional import of `INBOUND_UUID`.
4. **Optional `--install`:** Run upstream 3x-ui installer; warn about GPL attribution and interactive prompts (panel port must not be 443; prefer custom SSL paths to existing certs or HTTP + SSH tunnel per prior discussion).
5. **Finalize (default after user confirms):**
   - `systemctl stop xray` && `systemctl disable xray`
   - Verify port `CFG_INBOUND_PORT` listener (inform if still `xray`)
   - Remind: configure inbound in 3x-ui **before** expecting traffic; CDN relay unchanged
6. **Record state** in `/etc/xhttp-installer/3xui.env` (mode 600): `INTEGRATED_DATE`, `CHECKLIST_FILE`, `XRAY_BACKUP`, `THREE_XUI_INSTALLED=true|false`.

**Explicit non-goals (Level 1):** No curl to 3x-ui API, no edits to `/usr/local/x-ui` DB, no modification of generated `config.json` by script.

---

### 2. Install script on server: [`Deploy-Ubuntu.sh`](Deploy-Ubuntu.sh)

In **`phase7_install_panel`**, after writing `/usr/local/bin/xhttp`:

- If [`scripts/integrate-3xui.sh`](scripts/integrate-3xui.sh) exists under `SCRIPT_DIR`, copy to **`/usr/local/bin/xhttp-3xui`** (`chmod +x`).
- If missing (edge case: incomplete repo), warn once in install log.

In **`phase6_summary`**, add one line under “Management Panel”:

- Run **`xhttp-3xui`** (or menu option 8) for 3x-ui user management setup guide.

In **`main()`**, after `phase6_summary`, optional non-blocking prompt (skippable with `n`):

```bash
read -rp "Set up 3x-ui user management now? [y/N]: " ...
[[ "${yn,,}" == y|yes ]] && xhttp-3xui || true
```

(Does not fail install if user declines.)

---

### 3. Extend embedded `xhttp` menu ([`Deploy-Ubuntu.sh`](Deploy-Ubuntu.sh) heredoc ~L2902–2928)

Add menu item **8) 3x-ui user management setup** → `exec /usr/local/bin/xhttp-3xui` (or inline call if binary missing, show “re-run installer or copy script”).

Update prompt to `Choose [0-8]:`.

In **`_uninstall`**, add a note (no auto-removal): 3x-ui is separate; run `x-ui uninstall` if desired.

---

### 4. Documentation

| File | Content |
|------|---------|
| [`docs/3X-UI-INTEGRATION.md`](docs/3X-UI-INTEGRATION.md) | Full walkthrough: prerequisites, `xhttp-3xui` flow, inbound table, external proxy, 10 GB per user in panel, rollback (`restore backup` + re-enable `xray`), troubleshooting (443 conflict, wrong host in link) |
| [`README_EN.md`](README_EN.md) | Short section + link to doc |
| [`README.md`](README.md) | Persian equivalent (brief) |

Rollback section (critical):

```bash
systemctl stop x-ui
cp /etc/xhttp-installer/xray-config.before-3xui.json /usr/local/etc/xray/config.json
systemctl enable xray && systemctl start xray
```

---

## Key values mapping (for checklist generator)

Reference implementation in script—must match installer link builder in [`phase7_install_panel`](Deploy-Ubuntu.sh) L2670–2677:

| `info.env` field | 3x-ui usage |
|------------------|-------------|
| `CFG_DOMAIN` | XHTTP `host` on **server** inbound |
| `VERCEL_HOST` | External proxy / client address, SNI, Host |
| `CFG_RELAY_PATH` | XHTTP path (server) |
| `CFG_PUBLIC_PATH` | Client path (often same `/api`) |
| `SSL_CERT` / `SSL_KEY` | TLS file paths in inbound |
| `XPADDING*` / `SC_MAX_POST_BYTES` | Netlify only—inbound + client `extra` |
| `INBOUND_UUID` | Optional first client UUID |

---

## Testing plan (manual on a VPS)

1. Fresh XHTTP install (Vercel + one domain) → `info.env` populated.
2. Run `xhttp-3xui` default (no `--install`) → checklist file correct vs `xhttp` config display.
3. Run with `--install` on a test box → 3x-ui installs; after manual inbound + `--finalize`, old `xray` disabled, client connects via CDN.
4. Netlify install path → checklist includes obfs keys.
5. Rollback procedure restores single-UUID installer behavior.
6. `xhttp` menu item 8 launches script.

---

## Risk mitigations

- **Port 443 conflict:** Script only disables `xray` after explicit confirmation; checklist warns to create 3x-ui inbound first.
- **Broken relay:** Checklist stresses do not change Vercel `TARGET_DOMAIN` / paths.
- **Panel SSL vs Xray SSL:** Document using existing `/etc/ssl/xhttp/...` for **inbound** only; panel on separate port.
- **Upstream 3x-ui changes:** Script pins to official install URL; no forked code.

---

## Out of scope (future Level 2)

- `phase8` API inbound creation
- Auto `subHost` / externalProxy via REST
- Bundling 3x-ui binary in repo
