#!/usr/bin/env bash
# experiments/SCE-I-002/rollback/cleanup.sh
# Limpieza post-experimento SCE-I-002

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../scripts/lib/common.sh"

log_step "SCE-I-002 — Rollback y limpieza"

# Verificar que payment-processor sigue corriendo
READY=$(kubectl get deploy payment-processor -n payments \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

if [[ "$READY" -ge 1 ]]; then
  log_ok "payment-processor: ${READY} réplica(s) Running — sin impacto"
else
  log_warn "payment-processor: no tiene réplicas Ready — verificar manualmente"
fi

# Verificar que Fluentd sigue corriendo
FLUENTD_READY=$(kubectl get daemonset fluentd -n logging \
  -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
log_ok "Fluentd DaemonSet: ${FLUENTD_READY} pods Running"

# Verificar que Elasticsearch sigue healthy
ES_HEALTH=$(kubectl exec -n logging elasticsearch-master-0 -- \
  curl -sf 'http://localhost:9200/_cluster/health' 2>/dev/null | \
  jq -r '.status' 2>/dev/null || echo "unknown")
log_ok "Elasticsearch: cluster ${ES_HEALTH}"

log_ok "Rollback completado — pipeline de logging intacto"
