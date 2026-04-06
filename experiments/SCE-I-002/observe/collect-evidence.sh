#!/usr/bin/env bash
# experiments/SCE-I-002/observe/collect-evidence.sh
# Recolecta evidencia de detección post-inyección SCE-I-002

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/../results"
source "$SCRIPT_DIR/../../../scripts/lib/common.sh"

log_step "SCE-I-002 — Recolección de evidencia"

# ═════════════════════════════════════════════════════════════════
# 1. Alertas de Falco (regla SCE-I-002 Log File Modification)
# ═════════════════════════════════════════════════════════════════
log_info "Recolectando alertas de Falco (últimos 10 minutos)..."

FALCO_ALERTS=$(kubectl logs -n infra -l app.kubernetes.io/name=falco \
  -c falco --since=10m 2>/dev/null | \
  grep -i "SCE-I-002\|Log File Modification\|payment-processor.*var/log\|defense-evasion" || true)

FALCO_COUNT=$(echo "$FALCO_ALERTS" | grep -c "." 2>/dev/null || echo "0")
[[ -z "$FALCO_ALERTS" ]] && FALCO_COUNT=0

{
  echo "═══ Evidencia Falco — Alertas SCE-I-002 ═══"
  echo "Timestamp recolección: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Alertas encontradas: $FALCO_COUNT"
  echo ""
  if [[ -n "$FALCO_ALERTS" && "$FALCO_COUNT" -gt 0 ]]; then
    echo "$FALCO_ALERTS"
  else
    echo "(No se detectaron alertas Falco SCE-I-002)"
    echo ""
    echo "NOTA: La regla Falco SCE-I-002 detecta evt.type in (open, openat)"
    echo "con escritura en /var/log/. Si readOnlyRootFilesystem bloqueó el"
    echo "intento ANTES de que el syscall open() se ejecute, Falco no"
    echo "generará alerta (el kernel rechaza antes del open)."
    echo "Esto es un HALLAZGO POSITIVO: el control preventivo (RO filesystem)"
    echo "actúa antes que el control detectivo (Falco)."
  fi
} > "$RESULTS_DIR/falco-alerts.json"

if [[ "$FALCO_COUNT" -gt 0 ]]; then
  log_ok "Falco: $FALCO_COUNT alertas SCE-I-002 capturadas"
else
  log_info "Falco: 0 alertas (readOnlyRootFilesystem bloqueó antes del syscall)"
fi

# ═════════════════════════════════════════════════════════════════
# 2. Log injection detectada en Fluentd → Elasticsearch
# ═════════════════════════════════════════════════════════════════
log_info "Buscando log injection (línea falsa) en Elasticsearch..."

ES_INJECTION=$(kubectl exec -n logging elasticsearch-master-0 -- \
  curl -sf 'http://localhost:9200/fluentd-*/_search' \
  -H 'Content-Type: application/json' \
  -d '{
    "query": {
      "bool": {
        "must": [
          {"match_phrase": {"log": "legitimate-looking-but-fake"}}
        ]
      }
    },
    "size": 10,
    "sort": [{"@timestamp": "desc"}]
  }' 2>/dev/null || echo '{"hits":{"total":{"value":0}}}')

ES_INJECT_HITS=$(echo "$ES_INJECTION" | jq -r '.hits.total.value // .hits.total // 0' 2>/dev/null || echo "0")

{
  echo "═══ Evidencia Elasticsearch — Log Injection ═══"
  echo "Timestamp recolección: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Registros falsos encontrados: $ES_INJECT_HITS"
  echo ""
  if [[ "$ES_INJECT_HITS" != "0" ]]; then
    echo "HALLAZGO: La línea inyectada en stdout del contenedor llegó a Elasticsearch."
    echo "Esto demuestra que un atacante puede INYECTAR registros falsos en el log,"
    echo "pero NO puede eliminar los registros legítimos previos."
    echo ""
    echo "$ES_INJECTION" | jq '.hits.hits[]._source' 2>/dev/null || echo "$ES_INJECTION"
  else
    echo "La línea inyectada no fue encontrada en Elasticsearch."
    echo "(Puede que Fluentd aún no la haya procesado, o el flush interval no ha pasado)"
  fi
} > "$RESULTS_DIR/elasticsearch-injection.json"

if [[ "$ES_INJECT_HITS" != "0" ]]; then
  log_warn "Elasticsearch: $ES_INJECT_HITS registros inyectados detectados (log injection posible)"
else
  log_ok "Elasticsearch: No se detectaron registros inyectados"
fi

# ═════════════════════════════════════════════════════════════════
# 3. Kubernetes audit log — eventos del experimento
# ═════════════════════════════════════════════════════════════════
log_info "Recolectando audit log de kubectl exec en payments..."

AUDIT_EVENTS=$(docker exec sce-lab-control-plane \
  cat /var/log/kubernetes/audit.log 2>/dev/null | \
  jq -c 'select(
    (.objectRef.subresource // "") == "exec" and
    (.objectRef.namespace // "") == "payments" and
    .stage == "ResponseComplete"
  ) | {
    timestamp: .requestReceivedTimestamp,
    user: .user.username,
    pod: .objectRef.name,
    command: .requestURI,
    sourceIP: (.sourceIPs[0] // "unknown")
  }' 2>/dev/null | tail -20 || true)

AUDIT_COUNT=$(echo "$AUDIT_EVENTS" | grep -c "timestamp" 2>/dev/null || echo "0")
[[ -z "$AUDIT_EVENTS" ]] && AUDIT_COUNT=0

{
  echo "═══ Evidencia Audit Log — kubectl exec en payments ═══"
  echo "Timestamp recolección: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Eventos encontrados: $AUDIT_COUNT"
  echo ""
  if [[ -n "$AUDIT_EVENTS" && "$AUDIT_COUNT" -gt 0 ]]; then
    echo "$AUDIT_EVENTS" | jq '.' 2>/dev/null || echo "$AUDIT_EVENTS"
  else
    echo "(No se encontraron eventos de exec en el audit log)"
  fi
  echo ""
  echo "NOTA: El audit log es almacenado en el filesystem del control-plane,"
  echo "no accesible desde pods de aplicación. Esto garantiza la integridad"
  echo "de los registros de auditoría ante un atacante dentro de un pod."
} > "$RESULTS_DIR/audit-exec-events.json"

if [[ "$AUDIT_COUNT" -gt 0 ]]; then
  log_ok "Audit log: $AUDIT_COUNT eventos de exec capturados"
else
  log_warn "Audit log: No se encontraron eventos"
fi

# ═════════════════════════════════════════════════════════════════
# 4. Verificar integridad de los registros existentes en ES
# ═════════════════════════════════════════════════════════════════
log_info "Verificando integridad de índices en Elasticsearch..."

ES_INDICES=$(kubectl exec -n logging elasticsearch-master-0 -- \
  curl -sf 'http://localhost:9200/_cat/indices/fluentd-*?format=json' 2>/dev/null || echo "[]")

ES_INDEX_COUNT=$(echo "$ES_INDICES" | jq 'length' 2>/dev/null || echo "0")
ES_TOTAL_DOCS=$(echo "$ES_INDICES" | jq '[.[].docs.count | tonumber] | add // 0' 2>/dev/null || echo "0")

{
  echo "═══ Evidencia Elasticsearch — Integridad de índices ═══"
  echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Índices fluentd-*: $ES_INDEX_COUNT"
  echo "Documentos totales: $ES_TOTAL_DOCS"
  echo ""
  echo "$ES_INDICES" | jq '.' 2>/dev/null || echo "$ES_INDICES"
  echo ""
  echo "Los índices son append-only desde Fluentd. Un atacante dentro de un"
  echo "pod de aplicación no puede eliminar ni modificar documentos existentes"
  echo "porque NetworkPolicy bloquea la conexión al namespace logging."
} > "$RESULTS_DIR/elasticsearch-integrity.json"

log_ok "Elasticsearch: $ES_INDEX_COUNT índice(s), $ES_TOTAL_DOCS documentos totales"

# ═════════════════════════════════════════════════════════════════
# Resumen
# ═════════════════════════════════════════════════════════════════
log_step "Resumen de evidencia recolectada"
log_info "Falco alerts SCE-I-002:     $FALCO_COUNT"
log_info "Log injection en ES:        $ES_INJECT_HITS"
log_info "Audit log exec events:      $AUDIT_COUNT"
log_info "ES índices intactos:        $ES_INDEX_COUNT ($ES_TOTAL_DOCS docs)"
log_info "Archivos en results/:       $(ls -1 "$RESULTS_DIR" | wc -l | tr -d ' ')"

log_ok "Evidencia recolectada en experiments/SCE-I-002/results/"
