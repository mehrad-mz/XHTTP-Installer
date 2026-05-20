#!/usr/bin/env bash
# =============================================================
#  XHTTP Installer — Optional 3x-ui integration (Level 1)
#  Copyright (C) 2025 avaco_cloud
#  Repository: https://github.com/avacocloud/XHTTP-Installer
#  Licensed under GPL-3.0. See LICENSE file.
# =============================================================
# Standalone helper: does NOT modify Deploy-Ubuntu.sh or core installer.
# Reads /etc/xhttp-installer/info.env after a successful XHTTP install.
#
# Usage:
#   sudo bash scripts/integrate-3xui.sh [options]
#   sudo xhttp-3xui [options]   # after --install-bin

set -euo pipefail

readonly STATE_DIR="/etc/xhttp-installer"
readonly INFO_ENV="${STATE_DIR}/info.env"
readonly THREE_XUI_INSTALL_URL="https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"
readonly XRAY_CFG="/usr/local/etc/xray/config.json"

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

C_CYAN="\033[1;36m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_GRAY="\033[0;90m"
C_WHITE="\033[1;37m"
C_RESET="\033[0m"

info() { echo -e "${C_CYAN}➜${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}✔${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}⚠${C_RESET} $*"; }
fail() { echo -e "${C_RED}✘${C_RESET} $*"; exit 1; }

DO_INSTALL=false
DO_FINALIZE_ONLY=false
DO_INSTALL_BIN=false
SKIP_FINALIZE_PROMPT=false

usage() {
  cat <<'EOF'
XHTTP Installer — optional 3x-ui integration (Level 1)

This script does NOT change XHTTP-Installer core code. Run it after a
successful install when /etc/xhttp-installer/info.env exists.

Usage:
  sudo bash scripts/integrate-3xui.sh [options]

Options:
  (none)          Backup Xray config, generate 3x-ui checklist, optional finalize
  --install       Also run the official 3x-ui install.sh (interactive)
  --finalize      Skip 3x-ui install; only backup + stop/disable xray service
  --install-bin   Copy this script to /usr/local/bin/xhttp-3xui
  --yes-finalize  Disable xray without confirmation (use with care)
  --help          Show this help

Recommended order:
  1. Run with --install (or install 3x-ui yourself)
  2. Configure inbound in 3x-ui using the generated checklist
  3. Run again with --finalize (or confirm finalize when prompted)

Documentation:
  docs/3X-UI-INTEGRATION.md

Rollback (printed at end of checklist):
  systemctl stop x-ui
  cp <backup> /usr/local/etc/xray/config.json
  systemctl enable xray && systemctl start xray
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install) DO_INSTALL=true ;;
      --finalize) DO_FINALIZE_ONLY=true ;;
      --install-bin) DO_INSTALL_BIN=true ;;
      --yes-finalize) SKIP_FINALIZE_PROMPT=true ;;
      --help|-h) usage; exit 0 ;;
      *)
        fail "Unknown option: $1 (use --help)"
        ;;
    esac
    shift
  done
}

require_root() {
  [[ $EUID -eq 0 ]] || fail "Run as root: sudo bash scripts/integrate-3xui.sh"
}

require_prereqs() {
  require_root
  command -v systemctl &>/dev/null || fail "systemctl is required"
  [[ -f "$INFO_ENV" ]] || fail "Missing ${INFO_ENV}. Run XHTTP-Installer first."
  # shellcheck source=/dev/null
  source "$INFO_ENV"
  [[ -n "${CFG_DOMAIN:-}" ]] || fail "CFG_DOMAIN missing in ${INFO_ENV}"
  [[ -n "${VERCEL_HOST:-}" ]] || fail "VERCEL_HOST missing in ${INFO_ENV}"
}

confirm() {
  local prompt="$1"
  local answer
  read -rp "$(echo -e "${C_YELLOW}?${C_RESET} ${prompt} [y/N]: ")" answer
  case "${answer,,}" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

install_bin() {
  install -m 755 "$SCRIPT_PATH" /usr/local/bin/xhttp-3xui
  ok "Installed → /usr/local/bin/xhttp-3xui"
}

backup_xray_config() {
  XRAY_BACKUP=""
  if [[ -f "$XRAY_CFG" ]]; then
    XRAY_BACKUP="${STATE_DIR}/xray-config.before-3xui.$(date +%Y%m%d%H%M%S).json"
    cp "$XRAY_CFG" "$XRAY_BACKUP"
    chmod 600 "$XRAY_BACKUP"
    ok "Backed up Xray config → ${XRAY_BACKUP}"
  else
    warn "No ${XRAY_CFG} found — backup skipped"
  fi
}

build_extra_json_hint() {
  if [[ "${CFG_PLATFORM:-vercel}" == "netlify" ]]; then
    printf '{"xPaddingBytes":"%s","xPaddingObfsMode":true,"xPaddingKey":"%s","xPaddingHeader":"%s","scMaxEachPostBytes":"%s"}' \
      "${XPADDING:-10-50}" "${XPADDING_KEY:-}" "${XPADDING_HEADER:-}" "${SC_MAX_POST_BYTES:-1000000}"
  else
    printf '{"xPaddingBytes":"%s"}' "${XPADDING:-100-1000}"
  fi
}

write_checklist() {
  local checklist_file="${STATE_DIR}/3xui-checklist.txt"
  local extra_json
  extra_json="$(build_extra_json_hint)"

  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"

  cat > "$checklist_file" <<CHECKLIST
================================================================================
XHTTP Installer — 3x-ui configuration checklist
Generated: $(date -Iseconds)
Platform: ${CFG_PLATFORM:-unknown}
================================================================================

IMPORTANT
---------
- Do NOT change Vercel/Netlify relay env (TARGET_DOMAIN, RELAY_PATH, etc.).
- 3x-ui panel port must NOT be ${CFG_INBOUND_PORT:-443} (use e.g. 2053).
- Create the inbound below in 3x-ui BEFORE disabling the installer xray service.
- Server XHTTP host is CFG_DOMAIN; client Address/SNI/Host is VERCEL_HOST.

--------------------------------------------------------------------------------
A) 3x-ui inbound (server — what Xray listens for behind the CDN)
--------------------------------------------------------------------------------
Protocol:        VLESS
Transport:       XHTTP (SplitHTTP)
Security:        TLS
Listen port:     ${CFG_INBOUND_PORT:-443}
Certificate:     ${SSL_CERT:-<set path in info.env>}
Private key:     ${SSL_KEY:-<set path in info.env>}
XHTTP path:      ${CFG_RELAY_PATH:-/api}
XHTTP host:      ${CFG_DOMAIN}
XHTTP mode:      auto
XHTTP padding:   ${XPADDING:-100-1000}
CHECKLIST

  if [[ "${CFG_PLATFORM:-vercel}" == "netlify" ]]; then
    cat >> "$checklist_file" <<CHECKLIST
Netlify obfs (inbound + must match client extra):
  xPaddingObfsMode:  true
  xPaddingKey:       ${XPADDING_KEY:-}
  xPaddingHeader:    ${XPADDING_HEADER:-}
  scMaxEachPostBytes: ${SC_MAX_POST_BYTES:-1000000}
CHECKLIST
  fi

  cat >> "$checklist_file" <<CHECKLIST

--------------------------------------------------------------------------------
B) Client / external proxy (CDN — what users connect to)
--------------------------------------------------------------------------------
Address:         ${VERCEL_HOST}
SNI:             ${VERCEL_HOST}
Request Host:    ${VERCEL_HOST}
Port:            443
Path:            ${CFG_PUBLIC_PATH:-/api}
Type:            xhttp
Client extra JSON (must match server):
  ${extra_json}

In 3x-ui inbound dialog set "External proxy" (or subscription subHost):
  dest / host:   ${VERCEL_HOST}
  port:          443

Reference link from XHTTP install (compare after editing in panel):
${CLIENT_LINK:-<not set>}

--------------------------------------------------------------------------------
C) First client (optional)
--------------------------------------------------------------------------------
Reuse existing UUID: ${INBOUND_UUID:-<not set>}

--------------------------------------------------------------------------------
D) Per-user limits in 3x-ui panel
--------------------------------------------------------------------------------
For each user: set Total GB (e.g. 10), expiry, enable subscription/QR as needed.
Note: XHTTP subscription links may fail on some 3x-ui versions — use QR/link per user.

--------------------------------------------------------------------------------
E) Panel install notes (--install)
--------------------------------------------------------------------------------
- Official installer: ${THREE_XUI_INSTALL_URL}
- Prefer panel on a high port (not 443).
- For panel TLS: reuse cert paths above OR HTTP + SSH tunnel / firewall.
- 3x-ui is GPL-3.0; attribution required if redistributed.

--------------------------------------------------------------------------------
ROLLBACK (restore installer-only Xray)
--------------------------------------------------------------------------------
systemctl stop x-ui
systemctl disable x-ui
cp ${XRAY_BACKUP:-/etc/xhttp-installer/xray-config.before-3xui.*.json} ${XRAY_CFG}
systemctl enable xray
systemctl start xray

================================================================================
CHECKLIST

  chmod 600 "$checklist_file"
  CHECKLIST_FILE="$checklist_file"
  ok "Checklist written → ${checklist_file}"
}

print_checklist() {
  echo ""
  echo -e "${C_CYAN}──────────── 3x-ui checklist (summary) ────────────${C_RESET}"
  echo -e "  ${C_WHITE}Server domain (XHTTP host):${C_RESET}  ${CFG_DOMAIN}"
  echo -e "  ${C_WHITE}CDN host (client SNI/Host):${C_RESET}   ${VERCEL_HOST}"
  echo -e "  ${C_WHITE}Inbound port:${C_RESET}                 ${CFG_INBOUND_PORT:-443}"
  echo -e "  ${C_WHITE}Paths:${C_RESET} server=${CFG_RELAY_PATH:-/api}  client=${CFG_PUBLIC_PATH:-/api}"
  echo -e "  ${C_WHITE}TLS cert:${C_RESET}                   ${SSL_CERT:-n/a}"
  if [[ "${CFG_PLATFORM:-vercel}" == "netlify" ]]; then
    echo -e "  ${C_WHITE}Netlify padding:${C_RESET}            ${XPADDING:-10-50} key=${XPADDING_KEY:-} header=${XPADDING_HEADER:-}"
  else
    echo -e "  ${C_WHITE}Vercel padding:${C_RESET}             ${XPADDING:-100-1000}"
  fi
  echo -e "  ${C_WHITE}Full checklist:${C_RESET}             ${CHECKLIST_FILE}"
  echo -e "${C_CYAN}──────────────────────────────────────────────────${C_RESET}"
  echo ""
}

run_3xui_install() {
  info "Launching official 3x-ui installer (interactive)..."
  warn "Choose a panel port other than ${CFG_INBOUND_PORT:-443}."
  warn "For panel SSL, prefer custom cert paths or HTTP + SSH tunnel."
  bash <(curl -Ls "$THREE_XUI_INSTALL_URL")
  THREE_XUI_INSTALLED=true
  ok "3x-ui install script finished — configure inbound using the checklist"
}

finalize_xray_handoff() {
  if ! systemctl list-unit-files xray.service &>/dev/null 2>&1; then
    warn "xray.service not found — skip handoff"
    return 0
  fi

  if systemctl is-active --quiet xray 2>/dev/null; then
    info "Stopping and disabling installer xray service (handoff to 3x-ui)..."
    systemctl stop xray
    systemctl disable xray
    ok "xray stopped and disabled"
  else
    warn "xray is not active"
    systemctl disable xray 2>/dev/null || true
  fi

  if command -v ss &>/dev/null; then
    local listener
    listener=$(ss -tlnp 2>/dev/null | grep ":${CFG_INBOUND_PORT:-443} " || true)
    if [[ -n "$listener" ]]; then
      warn "Port ${CFG_INBOUND_PORT:-443} is still in use:"
      echo -e "${C_GRAY}  ${listener}${C_RESET}"
      warn "Ensure 3x-ui inbound is listening before testing clients."
    else
      ok "Port ${CFG_INBOUND_PORT:-443} is free (configure 3x-ui inbound to use it)"
    fi
  fi
}

maybe_finalize() {
  if [[ "$DO_FINALIZE_ONLY" == true ]]; then
    if [[ "$SKIP_FINALIZE_PROMPT" != true ]]; then
      confirm "Stop and disable installer xray service now?" || return 0
    fi
    finalize_xray_handoff
    return 0
  fi

  if [[ "$SKIP_FINALIZE_PROMPT" == true ]]; then
    finalize_xray_handoff
    return 0
  fi

  echo ""
  warn "Only finalize AFTER you created the matching inbound in 3x-ui."
  if confirm "Stop and disable installer xray service now?"; then
    finalize_xray_handoff
  else
    info "Skipped finalize — run later: sudo xhttp-3xui --finalize"
  fi
}

write_state() {
  local state_file="${STATE_DIR}/3xui.env"
  cat > "$state_file" <<STATE
# XHTTP Installer — 3x-ui integration state (Level 1)
INTEGRATED_DATE="$(date -Iseconds)"
CHECKLIST_FILE="${CHECKLIST_FILE:-}"
XRAY_BACKUP="${XRAY_BACKUP:-}"
THREE_XUI_INSTALLED=${THREE_XUI_INSTALLED:-false}
STATE
  chmod 600 "$state_file"
  ok "State saved → ${state_file}"
}

print_rollback() {
  echo ""
  echo -e "${C_CYAN}── Rollback (restore installer-only setup) ──${C_RESET}"
  echo "  systemctl stop x-ui"
  echo "  systemctl disable x-ui"
  if [[ -n "${XRAY_BACKUP:-}" ]]; then
    echo "  cp ${XRAY_BACKUP} ${XRAY_CFG}"
  else
    echo "  cp <your-backup.json> ${XRAY_CFG}"
  fi
  echo "  systemctl enable xray && systemctl start xray"
  echo ""
  echo -e "  See ${C_WHITE}docs/3X-UI-INTEGRATION.md${C_RESET} for details."
  echo ""
}

main() {
  parse_args "$@"
  THREE_XUI_INSTALLED=false

  [[ "$DO_INSTALL_BIN" == true ]] && install_bin

  require_prereqs

  echo ""
  echo -e "${C_WHITE}XHTTP Installer — 3x-ui integration (Level 1, standalone)${C_RESET}"
  echo -e "${C_GRAY}Core installer is unchanged; this script only reads info.env${C_RESET}"
  echo ""

  backup_xray_config
  write_checklist
  print_checklist

  if [[ "$DO_INSTALL" == true ]]; then
    run_3xui_install
  elif [[ "$DO_FINALIZE_ONLY" != true ]]; then
    info "To install 3x-ui: re-run with --install"
  fi

  maybe_finalize
  write_state
  print_rollback

  ok "Done. Open the checklist and 3x-ui panel to finish setup."
}

main "$@"
