#!/usr/bin/env bash
# experiments/SCE-C-001/observe/collect-evidence.sh
# Recolecta evidencia de detección post-inyección

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/../results"
source "$SCRIPT_DIR/../../../scripts/lib/common.sh"

log_step "SCE-C-001 — Recolección de evidencia"

# ═════════════════════════════════════════════════════════════════
# 1. Alertas de Falco
# ═════════════════════════════════════════════════════════════════
log_info "Recolectando alertas de Falco (últimos 10 minutos)..."

# Obtener logs de todos los pods Falco
FALCO_ALERTS=$(kubectl logs -n infra -l app.kubernetes.io/name=falco \
  -c falco --since=10m 2>/dev/null | grep -i "SCE-C-001\|payment-processor\|Unexpected\|Exfiltration\|Env Var" || true)

FALCO_COUNT=$(echo "$FALCO_ALERTS" | grep -c "." || true)

{
  echo "═══ Evidencia Falco — Alertas SCE-C-001 ═══"
  echo "Timestamp recolección: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Alertas encontradas: $FALCO_COUNT"
  echo ""
  if [[ -n "$FALCO_ALERTS" ]]; then
    echo "$FALCO_ALERTS"
  else
    echo "(No se detectaron alertas Falco en los últimos 10 minutos)"
    echo ""
    echo "NOTA: Es posible que las reglas Falco SCE-C-001 no se hayan"
    echo "activado porque los kubectl exec se ejecutan desde fuera del pod"
    echo "(no desde un proceso dentro del contenedor). Las reglas de Falco"
    echo "monitorean syscalls dentro del contenedor."
  fi
} > "$RESULTS_DIR/falco-alerts.json"

if [[ $FALCO_COUNT -gt 0 ]]; then
  log_ok "Falco: $FALCO_COUNT alertas capturadas"
else
  log_warn "Falco: No se capturaron alertas SCE-C-001"
fi

# ═════════════════════════════════════════════════════════════════
# 2. Kubernetes Audit Log — eventos de exec
# ═════════════════════════════════════════════════════════════════
log_info "Recolectando eventos de kubectl exec del audit log..."

AUDIT_EVENTS=$(docker exec sce-lab-control-plane \
  cat /var/log/kubernetes/audit.log 2>/dev/null | \
  jq -c 'select(
    (.objectRef.subresource // "") == "exec" and
    (.objectRef.namespace // "") == "payments" and
    .stage == "ResponseComplete"
  ) | {
    timestamp: .requestReceivedTimestamp,
    user: .user.username,
    verb: .verb,
    resource: .objectRef.resource,
    name: .objectRef.name,
    namespace: .objectRef.namespace,
    subresource: .objectRef.subresource,
    command: .requestURI,
    sourceIP: (.sourceIPs[0] // "unknown"),
    decision: .annotations["authorization.k8s.io/decision"]
  }' 2>/dev/null | tail -20 || true)

AUDIT_COUNT=$(echo "$AUDIT_EVENTS" | grep -c "." || true)

{
  echo "═══ Evidencia Audit Log — kubectl exec en payments ═══"
  echo "Timestamp recolección: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Eventos encontrados: $AUDIT_COUNT"
  echo ""
  if [[ -n "$AUDIT_EVENTS" ]]; then
    echo "$AUDIT_EVENTS" | jq '.' 2>/dev/null || echo "$AUDIT_EVENTS"
  else
    echo "(No se encontraron eventos de exec en el audit log)"
  fi
} > "$RESULTS_DIR/audit-exec-events.json"

if [[ $AUDIT_COUNT -gt 0 ]]; then
  log_ok "Audit log: $AUDIT_COUNT eventos de exec capturados"
else
  log_warn "Audit log: No se encontraron eventos de exec"
fi

# ═════════════════════════════════════════════════════════════════
# 3. Elasticsearch — eventos de Falco indexados
# ═════════════════════════════════════════════════════════════════
log_info "Consultando Elasticsearch por eventos Falco..."

ES_RESULT=$(kubectl exec -n logging elasticsearch-master-0 -- \
  curl -sf 'http://localhost:9200/fluentd-*/_search' \
  -H 'Content-Type: application/json' \
  -d '{
    "query": {
      "bool": {
        "should": [
          {"match_phrase": {"log": "SCE-C-001"}},
          {"match_phrase": {"log": "payment-processor"}},
          {"match_phrase": {"kubernetes.labels.app_kubernetes_io/name": "falco"}}
        ],
        "minimum_should_match": 1
      }
    },
    "size": 50,
    "sort": [{"@timestamp": "desc"}]
  }' 2>/dev/null || echo '{"hits":{"total":{"value":0}}}')

ES_HITS=$(echo "$ES_RESULT" | jq -r '.hits.total.value // .hits.total // 0' 2>/dev/null || echo "0")

{
  echo "═══ Evidencia Elasticsearch — Eventos Falco indexados ═══"
  echo "Timestamp recolección: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Hits encontrados: $ES_HITS"
  echo ""
  echo "$ES_RESULT" | jq '.' 2>/dev/null || echo "$ES_RESULT"
} > "$RESULTS_DIR/elasticsearch-falco.json"

if [[ "$ES_HITS" != "0" ]]; then
  log_ok "Elasticsearch: $ES_HITS eventos encontrados"
else
  log_warn "Elasticsearch: No se encontraron eventos Falco indexados"
fi

# ═════════════════════════════════════════════════════════════════
# 4. Resumen de evidencia recolectada
# ═════════════════════════════════════════════════════════════════
log_step "Resumen de evidencia recolectada"
log_info "Falco alerts:          $FALCO_COUNT"
log_info "Audit log exec events: $AUDIT_COUNT"
log_info "Elasticsearch hits:    $ES_HITS"
log_info "Archivos en results/:  $(ls -1 "$RESULTS_DIR" | wc -l | tr -d ' ')"

log_ok "Evidencia recolectada en experiments/SCE-C-001/results/"
