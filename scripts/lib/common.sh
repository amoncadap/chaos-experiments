#!/usr/bin/env bash
# scripts/lib/common.sh
# Librería compartida para los experimentos SCE Lab

# ─── Colores ───────────────────────────────────────────────────────────────
BOLD='\033[1m'
NC='\033[0m'       # No Color / Reset
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'

# ─── Logging ───────────────────────────────────────────────────────────────
log_ok()    { echo -e "  ${GREEN}✓${NC}  $*"; }
log_warn()  { echo -e "  ${YELLOW}⚠${NC}  $*"; }
log_error() { echo -e "  ${RED}✗${NC}  $*"; }
log_info()  { echo -e "  ${CYAN}→${NC}  $*"; }
log_step()  { echo -e "\n${BOLD}${BLUE}── $* ──────────────────────────────────────────────${NC}"; }

# ─── Timing ────────────────────────────────────────────────────────────────
# record_timing VAR_NAME  — captura timestamp en ms en la variable dada
record_timing() {
  local var_name="$1"
  local ts
  ts=$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null \
    || perl -MTime::HiRes -e 'print int(Time::HiRes::time()*1000)' 2>/dev/null \
    || echo "$(($(date +%s) * 1000))")
  printf -v "$var_name" '%s' "$ts"
}

# elapsed_ms START_VAL END_VAL  — devuelve diferencia en ms
elapsed_ms() {
  local start="$1"
  local end="$2"
  echo $(( end - start ))
}

# ─── Precondiciones ────────────────────────────────────────────────────────
# assert_precondition "label" <command...>
# Ejecuta el comando; si falla, imprime error y termina con exit 1
assert_precondition() {
  local label="$1"
  shift
  if "$@" &>/dev/null 2>&1; then
    log_ok "Precondición OK: $label"
  else
    log_error "Precondición FALLIDA: $label"
    log_error "Comando fallido: $*"
    exit 1
  fi
}

# ─── Falco ─────────────────────────────────────────────────────────────────
check_falco() {
  if kubectl get daemonset falco -n falco &>/dev/null 2>&1 \
     || kubectl get daemonset -n infra -l app=falco &>/dev/null 2>&1; then
    log_ok "Falco DaemonSet detectado"
  else
    log_warn "Falco DaemonSet no encontrado — detección runtime puede no estar activa"
  fi
}
