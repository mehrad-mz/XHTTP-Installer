#!/usr/bin/env bash
# =============================================================
#  XHTTP Installer — Vercel cost tuning (standalone)
#  Sets budget relay env vars + optional maxDuration, redeploys.
#  Does NOT touch x-ui, xray, or Deploy-Ubuntu.sh.
# =============================================================
#
# Usage:
#   sudo bash scripts/tune-vercel-cost.sh [options]
#   sudo xhttp-vercel-tune [options]          # after --install-bin
#
# Credentials (optional, chmod 600):
#   /etc/xhttp-installer/vercel.api
#     VERCEL_TOKEN=...
#     VERCEL_PROJECT=your-project-name
#     VERCEL_SCOPE=team-slug          # optional
#
set -euo pipefail

readonly STATE_DIR="/etc/xhttp-installer"
readonly INFO_ENV="${STATE_DIR}/info.env"
readonly SECRETS_FILE="${STATE_DIR}/vercel.api"
readonly LOG_DIR="/var/log/xhttp-installer"

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERCEL_DIR="${REPO_ROOT}/deploy/vercel"

C_CYAN="\033[1;36m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_GRAY="\033[0;90m"
C_WHITE="\033[1;37m"
C_RESET="\033[0m"

PROFILE="strict"
DO_DEPLOY=true
DO_INSTALL_BIN=false
DO_SAVE_SECRETS=false
TUNE_MAX_DURATION=true
DRY_RUN=false
SKIP_PROBE=false

LOG_FILE=""

log()  { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
info() { log "${C_CYAN}➜${C_RESET} $*"; }
ok()   { log "${C_GREEN}✔${C_RESET} $*"; }
warn() { log "${C_YELLOW}⚠${C_RESET} $*"; }
fail() { log "${C_RED}✘${C_RESET} $*"; exit 1; }

usage() {
  cat <<'EOF'
XHTTP Installer — tune Vercel relay for lower cost

Safe: only Vercel env + deploy/vercel deploy. Does NOT change 3x-ui or Xray on VPS.

Usage:
  sudo bash scripts/tune-vercel-cost.sh [options]

Options:
  --profile budget|strict|balanced   Preset limits (default: strict)
  --no-deploy                        Set env vars only; skip production deploy
  --no-duration-tune                 Do not change maxDuration in vercel.json / api/index.js
  --dry-run                          Print actions only; no Vercel changes
  --save-secrets                     After prompt, write token/project to vercel.api (600)
  --install-bin                      Install as /usr/local/bin/xhttp-vercel-tune
  --skip-probe                       Skip HTTPS probe to CDN host after deploy
  --help                             Show this help

Credentials:
  Create /etc/xhttp-installer/vercel.api (chmod 600) or you will be prompted:
    VERCEL_TOKEN=...
    VERCEL_PROJECT=relay-project-name
    VERCEL_SCOPE=optional-team-slug

Log file:
  /var/log/xhttp-installer/vercel-tune-YYYYMMDD-HHMMSS.log

Docs:
  docs/VERCEL-COST-TUNE.md
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)
        PROFILE="${2:-}"
        shift 2
        ;;
      --no-deploy) DO_DEPLOY=false; shift ;;
      --no-duration-tune) TUNE_MAX_DURATION=false; shift ;;
      --dry-run) DRY_RUN=true; DO_DEPLOY=false; shift ;;
      --save-secrets) DO_SAVE_SECRETS=true; shift ;;
      --install-bin) DO_INSTALL_BIN=true; shift ;;
      --skip-probe) SKIP_PROBE=true; shift ;;
      --help|-h) usage; exit 0 ;;
      *)
        fail "Unknown option: $1 (use --help)"
        ;;
    esac
  done
}

init_logging() {
  mkdir -p "$LOG_DIR"
  chmod 700 "$LOG_DIR" 2>/dev/null || true
  LOG_FILE="${LOG_DIR}/vercel-tune-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "${C_WHITE}=== XHTTP Vercel cost tune ===${C_RESET}"
  log "Log file: ${LOG_FILE}"
  log "Script:   ${SCRIPT_PATH}"
  log "Profile:  ${PROFILE}"
  log "Dry run:  ${DRY_RUN}"
}

require_root() {
  [[ $EUID -eq 0 ]] || fail "Run as root: sudo bash scripts/tune-vercel-cost.sh"
}

install_bin() {
  install -m 755 "$SCRIPT_PATH" /usr/local/bin/xhttp-vercel-tune
  ok "Installed → /usr/local/bin/xhttp-vercel-tune"
}

require_prereqs() {
  require_root
  command -v vercel &>/dev/null || fail "Vercel CLI not found. Install: npm i -g vercel"
  [[ -f "$INFO_ENV" ]] || fail "Missing ${INFO_ENV}. Run XHTTP-Installer first."
  # shellcheck source=/dev/null
  source "$INFO_ENV"
  [[ "${CFG_PLATFORM:-vercel}" == "vercel" ]] || fail "Platform is '${CFG_PLATFORM:-?}' — this script is for Vercel only."
  [[ -d "$VERCEL_DIR" ]] || fail "Missing ${VERCEL_DIR}. Clone XHTTP-Installer on this server."
  [[ -f "${VERCEL_DIR}/api/index.js" ]] || fail "Missing relay: ${VERCEL_DIR}/api/index.js"
  ok "Prerequisites OK (platform=vercel, domain=${CFG_DOMAIN:-?}, cdn=${VERCEL_HOST:-?})"
}

load_profile() {
  case "$PROFILE" in
    budget)
      MAX_INFLIGHT=32
      MAX_UP_BPS=524288
      MAX_DOWN_BPS=1048576
      UPSTREAM_TIMEOUT_MS=12000
      SUCCESS_LOG_SAMPLE_RATE=0
      SUCCESS_LOG_MIN_DURATION_MS=60000
      ERROR_LOG_MIN_INTERVAL_MS=10000
      MAX_DURATION=30
      ;;
    strict)
      MAX_INFLIGHT=12
      MAX_UP_BPS=262144
      MAX_DOWN_BPS=524288
      UPSTREAM_TIMEOUT_MS=10000
      SUCCESS_LOG_SAMPLE_RATE=0
      SUCCESS_LOG_MIN_DURATION_MS=60000
      ERROR_LOG_MIN_INTERVAL_MS=10000
      MAX_DURATION=25
      ;;
    balanced)
      MAX_INFLIGHT=48
      MAX_UP_BPS=1048576
      MAX_DOWN_BPS=1572864
      UPSTREAM_TIMEOUT_MS=15000
      SUCCESS_LOG_SAMPLE_RATE=0
      SUCCESS_LOG_MIN_DURATION_MS=30000
      ERROR_LOG_MIN_INTERVAL_MS=8000
      MAX_DURATION=45
      ;;
    *)
      fail "Unknown profile: ${PROFILE} (use budget, strict, or balanced)"
      ;;
  esac
  info "Profile '${PROFILE}' limits:"
  log "  MAX_INFLIGHT=${MAX_INFLIGHT}"
  log "  MAX_UP_BPS=${MAX_UP_BPS}"
  log "  MAX_DOWN_BPS=${MAX_DOWN_BPS}"
  log "  UPSTREAM_TIMEOUT_MS=${UPSTREAM_TIMEOUT_MS}"
  log "  SUCCESS_LOG_SAMPLE_RATE=${SUCCESS_LOG_SAMPLE_RATE}"
  log "  SUCCESS_LOG_MIN_DURATION_MS=${SUCCESS_LOG_MIN_DURATION_MS}"
  log "  ERROR_LOG_MIN_INTERVAL_MS=${ERROR_LOG_MIN_INTERVAL_MS}"
  log "  maxDuration (deploy files)=${MAX_DURATION}"
}

load_secrets() {
  VERCEL_TOKEN="${VERCEL_TOKEN:-}"
  VERCEL_PROJECT="${VERCEL_PROJECT:-}"
  VERCEL_SCOPE="${VERCEL_SCOPE:-}"

  if [[ -f "$SECRETS_FILE" ]]; then
    info "Loading secrets from ${SECRETS_FILE}"
    # shellcheck source=/dev/null
    source "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE" 2>/dev/null || true
  fi

  if [[ -z "${VERCEL_TOKEN// }" ]]; then
    read -rsp "$(echo -e "${C_WHITE}Vercel API token${C_RESET}: ")" VERCEL_TOKEN
    echo ""
    [[ -n "${VERCEL_TOKEN// }" ]] || fail "VERCEL_TOKEN is required"
  fi

  if [[ -z "${VERCEL_PROJECT// }" ]]; then
    if [[ -f "${VERCEL_DIR}/.vercel/project.json" ]] && command -v jq &>/dev/null; then
      local linked_name
      linked_name="$(jq -r '.projectName // empty' "${VERCEL_DIR}/.vercel/project.json" 2>/dev/null || true)"
      [[ -n "$linked_name" ]] && VERCEL_PROJECT="$linked_name"
    fi
  fi

  if [[ -z "${VERCEL_PROJECT// }" ]]; then
    read -rp "$(echo -e "${C_WHITE}Vercel project name${C_RESET}: ")" VERCEL_PROJECT
    [[ -n "${VERCEL_PROJECT// }" ]] || fail "VERCEL_PROJECT is required"
  fi

  if [[ "$DO_SAVE_SECRETS" == true ]] && [[ "$DRY_RUN" != true ]]; then
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    cat > "$SECRETS_FILE" <<SECRETS
# XHTTP Installer — Vercel API (chmod 600). Used by tune-vercel-cost.sh
VERCEL_TOKEN="${VERCEL_TOKEN}"
VERCEL_PROJECT="${VERCEL_PROJECT}"
VERCEL_SCOPE="${VERCEL_SCOPE}"
SECRETS
    chmod 600 "$SECRETS_FILE"
    ok "Saved secrets → ${SECRETS_FILE}"
  fi

  export VERCEL_TOKEN
  ok "Using Vercel project: ${VERCEL_PROJECT}"
  [[ -n "${VERCEL_SCOPE:-}" ]] && ok "Using Vercel scope: ${VERCEL_SCOPE}"
}

vercel_scope_args() {
  SCOPE_ARGS=()
  [[ -n "${VERCEL_SCOPE:-}" ]] && SCOPE_ARGS=(--scope "$VERCEL_SCOPE")
}

auth_vercel() {
  info "Checking Vercel token..."
  local whoami_out whoami_rc
  if [[ "$DRY_RUN" == true ]]; then
    ok "[dry-run] skip vercel whoami"
    return 0
  fi
  whoami_out=$(vercel whoami --token "$VERCEL_TOKEN" "${SCOPE_ARGS[@]}" 2>&1) || whoami_rc=$?
  whoami_rc=${whoami_rc:-0}
  if [[ $whoami_rc -ne 0 ]] || echo "$whoami_out" | grep -qiE "^(\s*)?Error:|invalid token|forbidden|401|403|unauthorized"; then
    fail "Vercel auth failed: $(echo "$whoami_out" | head -3)"
  fi
  ok "Vercel auth OK: $(echo "$whoami_out" | head -1 | tr -d '[:space:]')"
}

link_project() {
  info "Linking Vercel project in ${VERCEL_DIR}..."
  if [[ "$DRY_RUN" == true ]]; then
    ok "[dry-run] skip vercel link"
    return 0
  fi
  pushd "$VERCEL_DIR" > /dev/null
  if [[ -d .vercel ]]; then
    ok "Existing .vercel link found — re-linking to ${VERCEL_PROJECT}"
    rm -rf .vercel
  fi
  local link_out link_rc
  link_out=$(vercel link --yes --project "$VERCEL_PROJECT" \
    --token "$VERCEL_TOKEN" "${SCOPE_ARGS[@]}" 2>&1) || link_rc=$?
  link_rc=${link_rc:-0}
  popd > /dev/null
  if [[ $link_rc -ne 0 ]] && ! echo "$link_out" | grep -qiE "Linked to|Already linked"; then
    fail "vercel link failed: $(echo "$link_out" | tail -5)"
  fi
  ok "Linked to ${VERCEL_PROJECT}"
}

set_env_var() {
  local name="$1" value="$2"
  if [[ "$DRY_RUN" == true ]]; then
    log "  [dry-run] would set ${name}=${value}"
    return 0
  fi
  pushd "$VERCEL_DIR" > /dev/null
  local out rc
  out=$(printf '%s' "$value" | vercel env add "$name" production --force \
    --token "$VERCEL_TOKEN" "${SCOPE_ARGS[@]}" 2>&1) || rc=$?
  rc=${rc:-0}
  if [[ $rc -ne 0 ]] && ! echo "$out" | grep -qiE "added|created|updated|overwrote|saved"; then
    out=$(vercel env add "$name" production --value "$value" --force --yes \
      --token "$VERCEL_TOKEN" "${SCOPE_ARGS[@]}" 2>&1) || rc=$?
    rc=${rc:-0}
  fi
  popd > /dev/null
  if [[ $rc -eq 0 ]] || echo "$out" | grep -qiE "added|created|updated|overwrote|saved"; then
    ok "  ENV ${name}=${value}"
  else
    warn "  ENV ${name} failed (rc=${rc}): $(echo "$out" | head -1)"
    return 1
  fi
}

apply_env_vars() {
  info "Applying cost-tuning environment variables (Production only)..."
  warn "Not changing TARGET_DOMAIN, RELAY_PATH, PUBLIC_RELAY_PATH, or relay keys."

  local failed=0
  set_env_var "MAX_INFLIGHT" "$MAX_INFLIGHT" || failed=$((failed + 1))
  set_env_var "MAX_UP_BPS" "$MAX_UP_BPS" || failed=$((failed + 1))
  set_env_var "MAX_DOWN_BPS" "$MAX_DOWN_BPS" || failed=$((failed + 1))
  set_env_var "UPSTREAM_TIMEOUT_MS" "$UPSTREAM_TIMEOUT_MS" || failed=$((failed + 1))
  set_env_var "SUCCESS_LOG_SAMPLE_RATE" "$SUCCESS_LOG_SAMPLE_RATE" || failed=$((failed + 1))
  set_env_var "SUCCESS_LOG_MIN_DURATION_MS" "$SUCCESS_LOG_MIN_DURATION_MS" || failed=$((failed + 1))
  set_env_var "ERROR_LOG_MIN_INTERVAL_MS" "$ERROR_LOG_MIN_INTERVAL_MS" || failed=$((failed + 1))

  if [[ $failed -gt 0 ]]; then
    warn "${failed} env var(s) reported errors — check log and Vercel dashboard"
  else
    ok "All cost env vars applied"
  fi
}

verify_env_vars() {
  info "Verifying env var names on Vercel (production)..."
  if [[ "$DRY_RUN" == true ]]; then
    ok "[dry-run] skip verify"
    return 0
  fi
  pushd "$VERCEL_DIR" > /dev/null
  local env_list
  env_list=$(vercel env ls production --token "$VERCEL_TOKEN" "${SCOPE_ARGS[@]}" 2>&1 || true)
  popd > /dev/null

  local missing=0
  for name in MAX_INFLIGHT MAX_UP_BPS MAX_DOWN_BPS UPSTREAM_TIMEOUT_MS TARGET_DOMAIN; do
    if echo "$env_list" | grep -q "$name"; then
      ok "  listed: ${name}"
    else
      warn "  missing on Vercel: ${name}"
      missing=$((missing + 1))
    fi
  done

  info "Pulling production env to temporary file (values logged for cost vars only)..."
  local pull_file
  pull_file="$(mktemp)"
  pushd "$VERCEL_DIR" > /dev/null
  if vercel env pull "$pull_file" --environment=production --yes \
    --token "$VERCEL_TOKEN" "${SCOPE_ARGS[@]}" 2>&1; then
    popd > /dev/null
    local check_vars=(MAX_INFLIGHT MAX_UP_BPS MAX_DOWN_BPS UPSTREAM_TIMEOUT_MS)
    for name in "${check_vars[@]}"; do
      local expected actual
      case "$name" in
        MAX_INFLIGHT) expected="$MAX_INFLIGHT" ;;
        MAX_UP_BPS) expected="$MAX_UP_BPS" ;;
        MAX_DOWN_BPS) expected="$MAX_DOWN_BPS" ;;
        UPSTREAM_TIMEOUT_MS) expected="$UPSTREAM_TIMEOUT_MS" ;;
      esac
      actual="$(grep -E "^${name}=" "$pull_file" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
      if [[ "$actual" == "$expected" ]]; then
        ok "  verified value: ${name}=${actual}"
      elif [[ -z "$actual" ]]; then
        warn "  ${name} not in pull file (dashboard may hide values — check Vercel UI)"
      else
        warn "  ${name} pull=${actual} expected=${expected}"
      fi
    done
    rm -f "$pull_file"
  else
    popd > /dev/null
    warn "vercel env pull failed — names may still be set; dashboard hides values"
    rm -f "$pull_file"
  fi

  [[ $missing -eq 0 ]] || warn "Some expected vars missing from 'vercel env ls' output"
}

tune_max_duration_files() {
  [[ "$TUNE_MAX_DURATION" == true ]] || { info "Skipping maxDuration file edits (--no-duration-tune)"; return 0; }

  info "Setting maxDuration=${MAX_DURATION} in vercel.json and api/index.js..."
  local vjson="${VERCEL_DIR}/vercel.json"
  local indexjs="${VERCEL_DIR}/api/index.js"

  if [[ "$DRY_RUN" == true ]]; then
    ok "[dry-run] would patch maxDuration in ${vjson} and ${indexjs}"
    return 0
  fi

  if command -v python3 &>/dev/null; then
    python3 - "$vjson" "$MAX_DURATION" <<'PY'
import json, sys
path, dur = sys.argv[1], int(sys.argv[2])
with open(path, encoding="utf-8") as f:
    data = json.load(f)
data.setdefault("functions", {}).setdefault("api/index.js", {})["maxDuration"] = dur
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(f"patched {path}")
PY
    ok "  vercel.json maxDuration=${MAX_DURATION}"
  else
    warn "python3 missing — skip vercel.json patch (edit manually)"
  fi

  if [[ -f "$indexjs" ]]; then
    if grep -q 'maxDuration:' "$indexjs"; then
      sed -i.bak-vercel-tune "s/maxDuration: [0-9][0-9]*/maxDuration: ${MAX_DURATION}/" "$indexjs"
      rm -f "${indexjs}.bak-vercel-tune"
      ok "  api/index.js maxDuration=${MAX_DURATION}"
    else
      warn "  could not find maxDuration in api/index.js"
    fi
  fi
}

deploy_production() {
  if [[ "$DO_DEPLOY" != true ]]; then
    info "Skipping deploy (--no-deploy)"
    return 0
  fi
  info "Deploying to Vercel production..."
  if [[ "$DRY_RUN" == true ]]; then
    ok "[dry-run] skip vercel deploy"
    return 0
  fi

  pushd "$VERCEL_DIR" > /dev/null
  local deploy_out deploy_rc deploy_url
  deploy_out=$(vercel deploy --prod --yes --token "$VERCEL_TOKEN" "${SCOPE_ARGS[@]}" 2>&1) || deploy_rc=$?
  deploy_rc=${deploy_rc:-0}
  popd > /dev/null

  if [[ $deploy_rc -ne 0 ]]; then
    fail "Deploy failed (rc=${deploy_rc}):\n$(echo "$deploy_out" | tail -20)"
  fi

  deploy_url=$(echo "$deploy_out" | grep -oE 'https://[^[:space:]]+\.vercel\.app' | tail -1 || true)
  if [[ -n "$deploy_url" ]]; then
    ok "Deploy OK: ${deploy_url}"
  else
    ok "Deploy finished (URL not parsed from CLI output — check dashboard)"
    echo "$deploy_out" | tail -8
  fi
}

probe_cdn() {
  [[ "$SKIP_PROBE" == true ]] && { info "Skipping CDN probe (--skip-probe)"; return 0; }
  [[ -n "${VERCEL_HOST:-}" ]] || { warn "VERCEL_HOST empty in info.env — skip probe"; return 0; }

  local probe_url="https://${VERCEL_HOST}/"
  info "Probing CDN (expect 404/405, not 401): ${probe_url}"
  if [[ "$DRY_RUN" == true ]]; then
    ok "[dry-run] skip probe"
    return 0
  fi

  local code body
  code=$(curl -sk -o /dev/null --max-time 15 -w "%{http_code}" "$probe_url" 2>/dev/null || echo "000")
  body=$(curl -sk --max-time 15 "$probe_url" 2>/dev/null | head -c 400 || true)

  log "  HTTP ${code}"
  if [[ "$code" == "401" ]] || echo "$body" | grep -qi "Authentication Required\|_vercel_sso\|sso\.vercel\.com"; then
    warn "Deployment Protection may be ON (HTTP 401) — VPN will fail until disabled in Vercel dashboard"
  elif [[ "$code" == "000" ]]; then
    warn "Probe failed (timeout/DNS) — CDN may still be OK from clients"
  else
    ok "CDN reachable (HTTP ${code}) — relay not returning SSO 401"
  fi
}

print_xui_safety() {
  echo ""
  log "${C_CYAN}── VPS / 3x-ui (unchanged by this script) ──${C_RESET}"
  if command -v ss &>/dev/null; then
    local listener
    listener=$(ss -tlnp 2>/dev/null | grep ":${CFG_INBOUND_PORT:-443} " || true)
    if [[ -n "$listener" ]]; then
      log "  Port ${CFG_INBOUND_PORT:-443}: ${listener}"
    else
      warn "  Nothing listening on ${CFG_INBOUND_PORT:-443}"
    fi
  fi
  if systemctl is-active x-ui &>/dev/null; then
    log "  x-ui: active"
  else
    log "  x-ui: inactive"
  fi
  if systemctl is-active xray &>/dev/null; then
    log "  xray (installer): active"
  else
    log "  xray (installer): inactive"
  fi
  warn "  If both x-ui and xray fight for 443, fix in panel — not caused by this script."
  echo ""
}

print_summary() {
  echo ""
  log "${C_GREEN}══ Summary ══${C_RESET}"
  log "  Profile:     ${PROFILE}"
  log "  Log file:    ${LOG_FILE}"
  log "  CDN host:    ${VERCEL_HOST:-n/a}"
  log "  Server:      ${CFG_DOMAIN:-n/a}"
  log "  Next steps:"
  log "    1. Test VPN from a phone (browse 1–2 min)"
  log "    2. Vercel → Usage → watch Fluid Provisioned Memory over 24–48h"
  log "    3. Per-user GB limits → 3x-ui panel (not Vercel)"
  log "  Rollback env: set higher MAX_* in dashboard or re-run with --profile balanced"
  echo ""
}

main() {
  parse_args "$@"
  [[ "$DO_INSTALL_BIN" == true ]] && install_bin
  init_logging
  require_prereqs
  load_profile
  load_secrets
  vercel_scope_args
  auth_vercel
  link_project
  apply_env_vars
  verify_env_vars
  tune_max_duration_files
  deploy_production
  probe_cdn
  print_xui_safety
  print_summary
  ok "Done."
}

main "$@"
