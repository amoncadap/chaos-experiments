#!/usr/bin/env bash
# k9s-screenshot-monitor.sh
# Guía para tomar capturas de k9s durante la ejecución de experimentos SCE.
# Las capturas se realizan usando mcp__Claude_in_Chrome__computer desde Claude Code.
#
# Uso:
#   1. Abrir k9s en una ventana de terminal separada:
#        k9s -n <namespace>
#   2. En la sesión de Claude Code, correr este script para saber cuándo capturar:
#        ./k9s-screenshot-monitor.sh <experiment-id>
#   3. Claude Code invocará mcp__Claude_in_Chrome__computer en cada fase
#
# Vistas de k9s recomendadas por experimento:
#
#   SCE-C-001 (Confidencialidad — payments namespace):
#     Fase 0 (pre):    :pods → namespace: payments
#     Fase 1 (inject): :events → ver exec events en tiempo real
#     Fase 3 (egress): :networkpolicies → confirmar default-deny
#     Rollback:        :pods → estado final del namespace
#
#   SCE-D-001 (Disponibilidad — users namespace):
#     Fase 0 (pre):     :deployments → auth-service READY 1/1
#     Fase 2 (scale=0): :deployments → auth-service READY 0/0
#     Fase 3 (cache):   :events → ver Kubernetes scale events
#     Rollback:         :deployments → auth-service READY 1/1
#
#   SCE-I-002 (Integridad — payments namespace):
#     Fase 0 (pre):    :pods → payment-processor running
#     Fase 1 (write):  :events → ver eventos de filesystem
#     Fase 3 (ES):     :networkpolicies → bloqueo hacia logging ns
#     Rollback:        :pods → estado limpio

set -euo pipefail

EXPERIMENT_ID="${1:-}"

if [[ -z "$EXPERIMENT_ID" ]]; then
  echo "Uso: $0 <experiment-id>"
  echo "Ejemplo: $0 SCE-C-001"
  exit 1
fi

RESULTS_DIR="experiments/${EXPERIMENT_ID}/results"
K9S_DIR="${RESULTS_DIR}/k9s-screenshots"
MARKER="${RESULTS_DIR}/.screenshot-ready"

mkdir -p "${K9S_DIR}"

# ─── Colores ───────────────────────────────────────────────────────────────
CYAN='\033[0;36m'; BOLD='\033[1m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[k9s-monitor]${RESET} $*"; }
step() { echo -e "\n${BOLD}${GREEN}▶ $*${RESET}"; }
wait_enter() { echo -e "${YELLOW}  [Presiona ENTER cuando k9s muestre la vista indicada...]${RESET}"; read -r; }

# ─── Banner ────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║      SCE Lab — k9s Screenshot Monitor                       ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
log "Experimento: ${EXPERIMENT_ID}"
log "Capturas serán guardadas en: ${K9S_DIR}/"
echo ""

# ─── Instrucciones generales ──────────────────────────────────────────────
echo -e "${BOLD}INSTRUCCIONES:${RESET}"
echo "  1. Abre k9s en otra ventana de terminal"
echo "  2. Este script te indicará qué vista navegar en cada fase"
echo "  3. Claude Code tomará capturas con mcp__Claude_in_Chrome__computer"
echo "     y las guardará en ${K9S_DIR}/"
echo ""

# ─── Fases según el experimento ───────────────────────────────────────────
declare -a PHASES_LABEL
declare -a PHASES_K9S_CMD
declare -a PHASES_FILENAME

case "${EXPERIMENT_ID}" in
  SCE-C-001)
    PHASES_LABEL=( "Pre-ataque: pods en namespace payments" "Inyección: eventos kubectl exec" "Egress bloqueado: NetworkPolicies" "Rollback: estado final del cluster" )
    PHASES_K9S_CMD=( ":pods (namespace: payments)" ":events | filtrar por payments" ":networkpolicies (payments ns)" ":pods (payments) — estado limpio" )
    PHASES_FILENAME=( "phase0-pre-pods" "phase1-inject-events" "phase3-networkpolicies" "phase4-rollback-pods" )
    ;;
  SCE-D-001)
    PHASES_LABEL=( "Pre-ataque: auth-service READY 1/1" "Scale-to-zero: auth-service READY 0/0" "Cache window: eventos de scale" "Rollback: auth-service restaurado" )
    PHASES_K9S_CMD=( ":deployments (namespace: users)" ":deployments — auth-service=0 replicas" ":events (namespace: users)" ":deployments — auth-service READY 1/1" )
    PHASES_FILENAME=( "phase0-pre-deployments" "phase2-scale-zero-deployments" "phase3-cache-events" "phase4-rollback-deployments" )
    ;;
  SCE-I-002)
    PHASES_LABEL=( "Pre-ataque: pod payment-processor running" "Escritura /var/log: exec events" "Acceso ES: network blocked" "Rollback: estado limpio" )
    PHASES_K9S_CMD=( ":pods (namespace: payments)" ":events | filtrar exec attempts" ":networkpolicies (payments ns)" ":pods (payments) — estado limpio" )
    PHASES_FILENAME=( "phase0-pre-pods" "phase1-varlog-events" "phase3-networkpolicies" "phase4-rollback-pods" )
    ;;
  *)
    echo "Experimento no reconocido: ${EXPERIMENT_ID}"
    echo "Experimentos soportados: SCE-C-001, SCE-D-001, SCE-I-002"
    exit 1
    ;;
esac

# ─── Loop de fases ────────────────────────────────────────────────────────
for i in "${!PHASES_LABEL[@]}"; do
  PHASE_NUM=$((i + 1))
  LABEL="${PHASES_LABEL[$i]}"
  K9S_VIEW="${PHASES_K9S_CMD[$i]}"
  FILENAME="${PHASES_FILENAME[$i]}.png"
  DEST="${K9S_DIR}/${FILENAME}"

  step "FASE ${PHASE_NUM}/${#PHASES_LABEL[@]}: ${LABEL}"
  echo "  k9s: ${K9S_VIEW}"
  echo "  Destino captura: ${DEST}"
  wait_enter

  # Escribir marker con info de la fase para que Claude sepa qué capturar
  cat > "${MARKER}" <<EOF
{
  "experiment": "${EXPERIMENT_ID}",
  "phase": ${PHASE_NUM},
  "phase_label": "${LABEL}",
  "k9s_view": "${K9S_VIEW}",
  "screenshot_dest": "${DEST}",
  "ready_for_screenshot": true
}
EOF

  echo -e "  ${GREEN}✓ Marker escrito.${RESET} Claude Code tomará la captura ahora."
  echo -e "  ${CYAN}  → mcp__Claude_in_Chrome__computer${RESET} capturará la pantalla"
  echo -e "  ${CYAN}  → Guardará en: ${DEST}${RESET}"
  echo ""
done

# ─── Resumen final ────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Captura completada ──────────────────────────────────────────${RESET}"
echo ""
echo "Capturas guardadas en: ${K9S_DIR}/"
ls -1 "${K9S_DIR}/" 2>/dev/null | while read -r f; do echo "  · ${f}"; done || echo "  (ninguna captura guardada aún)"
echo ""
echo "Para ver las capturas en el dashboard:"
echo "  Las imágenes se mostrarán en la sección 'k9s Evidence' del dashboard.html"
echo "  cuando estén disponibles en ${K9S_DIR}/"
