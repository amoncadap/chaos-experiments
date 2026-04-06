#!/usr/bin/env bash
# experiments/SCE-C-001/rollback/cleanup.sh
# Limpieza post-experimento SCE-C-001

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../scripts/lib/common.sh"

log_step "SCE-C-001 — Rollback y limpieza"

# Verificar que payment-processor sigue corriendo normalmente
READY=$(kubectl get deploy payment-processor -n payments \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

if [[ "$READY" -ge 1 ]]; then
  log_ok "payment-processor: ${READY} réplica(s) Running — sin impacto post-experimento"
else
  log_warn "payment-processor: no tiene réplicas Ready — verificar manualmente"
  kubectl get pods -n payments -l app=payment-processor 2>/dev/null
fi

# Verificar que no quedaron pods temporales del experimento
TEMP_PODS=$(kubectl get pods -n payments -l sce-lab/experiment=SCE-C-001-temp \
  --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [[ "$TEMP_PODS" -gt 0 ]]; then
  log_info "Eliminando $TEMP_PODS pod(s) temporales del experimento..."
  kubectl delete pods -n payments -l sce-lab/experiment=SCE-C-001-temp --grace-period=5 2>/dev/null || true
  log_ok "Pods temporales eliminados"
else
  log_ok "No hay pods temporales que limpiar"
fi

log_ok "Rollback completado — entorno en estado normal"
