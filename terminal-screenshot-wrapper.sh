#!/usr/bin/env bash
# terminal-screenshot-wrapper.sh
# Wrapper para capturar output de terminal durante ejecución de experimentos SCE.
# Deja un marker file al completar cada fase para que Claude tome screenshots.
#
# Uso:
#   ./terminal-screenshot-wrapper.sh <experiment-id> <script-a-ejecutar>
#
# Ejemplo:
#   ./terminal-screenshot-wrapper.sh SCE-C-001 experiments/SCE-C-001/run-experiment.sh

set -euo pipefail

EXPERIMENT_ID="${1:-}"
SCRIPT_TO_RUN="${2:-}"

if [[ -z "$EXPERIMENT_ID" || -z "$SCRIPT_TO_RUN" ]]; then
  echo "Uso: $0 <experiment-id> <script-a-ejecutar>"
  echo "Ejemplo: $0 SCE-C-001 experiments/SCE-C-001/run-experiment.sh"
  exit 1
fi

TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
RESULTS_DIR="experiments/${EXPERIMENT_ID}/results"
LOGS_DIR="${RESULTS_DIR}/terminal-logs"
LOG_FILE="${LOGS_DIR}/session-${TIMESTAMP}.log"
SCREENSHOT_MARKER="${RESULTS_DIR}/.screenshot-ready"

mkdir -p "${LOGS_DIR}"

# ─── Colores ───────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log() { echo -e "${CYAN}[wrapper]${RESET} $*" | tee -a "${LOG_FILE}"; }

# ─── Banner ────────────────────────────────────────────────────────────────
{
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║         SCE Lab — Terminal Capture Wrapper                  ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  echo "  Experimento : ${EXPERIMENT_ID}"
  echo "  Script      : ${SCRIPT_TO_RUN}"
  echo "  Timestamp   : ${TIMESTAMP}"
  echo "  Log file    : ${LOG_FILE}"
  echo ""
} | tee -a "${LOG_FILE}"

# ─── Captura con script(1) si está disponible ─────────────────────────────
TYPESCRIPT="${LOGS_DIR}/typescript-${TIMESTAMP}"

run_with_capture() {
  if command -v script &>/dev/null; then
    log "Usando script(1) para grabar sesión completa → ${TYPESCRIPT}"
    # macOS: script -q <output> <command>
    # Linux: script -q -c <command> <output>
    if [[ "$(uname)" == "Darwin" ]]; then
      script -q "${TYPESCRIPT}" bash "${SCRIPT_TO_RUN}" 2>&1 | tee -a "${LOG_FILE}"
    else
      script -q -c "bash ${SCRIPT_TO_RUN}" "${TYPESCRIPT}" 2>&1 | tee -a "${LOG_FILE}"
    fi
  else
    log "script(1) no disponible, capturando con tee"
    bash "${SCRIPT_TO_RUN}" 2>&1 | tee -a "${LOG_FILE}"
  fi
}

# ─── Ejecutar experimento ──────────────────────────────────────────────────
log "Iniciando experimento ${EXPERIMENT_ID}..."
echo ""

EXIT_CODE=0
run_with_capture || EXIT_CODE=$?

echo ""
if [[ $EXIT_CODE -eq 0 ]]; then
  echo -e "${GREEN}✓ Experimento completado exitosamente (exit 0)${RESET}" | tee -a "${LOG_FILE}"
else
  echo -e "${YELLOW}⚠ Experimento terminó con exit code ${EXIT_CODE}${RESET}" | tee -a "${LOG_FILE}"
fi

# ─── Escribir marker para Claude screenshot ────────────────────────────────
cat > "${SCREENSHOT_MARKER}" <<EOF
{
  "experiment": "${EXPERIMENT_ID}",
  "timestamp": "${TIMESTAMP}",
  "exit_code": ${EXIT_CODE},
  "log_file": "${LOG_FILE}",
  "typescript": "${TYPESCRIPT}",
  "ready_for_screenshot": true
}
EOF

echo ""
echo -e "${BOLD}── Screenshot marker escrito ──────────────────────────────────${RESET}"
echo -e "   Archivo: ${SCREENSHOT_MARKER}"
echo -e "   Acción:  Invocar mcp__Claude_in_Chrome__computer para capturar k9s"
echo -e "            o mcp__Claude_Preview__preview_screenshot para el dashboard"
echo ""
log "Log guardado en: ${LOG_FILE}"
