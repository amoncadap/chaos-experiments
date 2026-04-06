#!/usr/bin/env bash
# experiments/SCE-D-001/observe/collect-evidence.sh
# Recolecta evidencia de detección post-inyección SCE-D-001

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/../results"
source "$SCRIPT_DIR/../../../scripts/lib/common.sh"

log_step "SCE-D-001 — Recolección de evidencia"

# ═════════════════════════════════════════════════════════════════
# 1. Estado actual del deployment auth-service
# ═════════════════════════════════════════════════════════════════
log_info "Capturando estado de auth-service..."

AUTH_STATUS=$(kubectl get deploy auth-service -n users -o yaml 2>/dev/null || echo "NOT FOUND")
AUTH_EVENTS=$(kubectl describe deploy auth-service -n users 2>/dev/null | \
  grep -A 20 "^Events:" || echo "No events")

{
  echo "═══ Evidencia: Estado de auth-service ═══"
  echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""
  echo "─── Deployment Status ───"
  kubectl get deploy auth-service -n users 2>/dev/null || echo "NOT FOUND"
  echo ""
  echo "─── Pods ───"
  kubectl get pods -n users -l app=auth-service 2>/dev/null || echo "No pods"
  echo ""
  echo "─── Events ───"
  echo "$AUTH_EVENTS"
} > "$RESULTS_DIR/auth-service-status.txt"

log_ok "Estado de auth-service capturado"

# ═════════════════════════════════════════════════════════════════
# 2. Logs de user-api (errores de conexión a auth-service)
# ═════════════════════════════════════════════════════════════════
log_info "Capturando logs de user-api (errores de autenticación)..."

USERAPI_POD=$(kubectl get pods -n users -l app=user-api \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

USERAPI_LOGS=""
if [[ -n "$USERAPI_POD" ]]; then
  USERAPI_LOGS=$(kubectl logs -n users "$USERAPI_POD" -c user-api \
    --since=5m 2>/dev/null | tail -50 || echo "No logs")
fi

{
  echo "═══ Evidencia: Logs de user-api ═══"
  echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Pod: $USERAPI_POD"
  echo ""
  echo "─── Últimos 50 líneas (5 min) ───"
  echo "$USERAPI_LOGS"
} > "$RESULTS_DIR/userapi-logs.txt"

ERROR_COUNT=$(echo "$USERAPI_LOGS" | grep -ci "error\|fail\|refused\|timeout\|503\|502" 2>/dev/null || echo "0")
log_ok "Logs de user-api: $ERROR_COUNT líneas con errores"

# ═════════════════════════════════════════════════════════════════
# 3. Kubernetes audit log — eventos de scale en users namespace
# ═════════════════════════════════════════════════════════════════
log_info "Recolectando audit log de scale events..."

AUDIT_EVENTS=$(docker exec sce-lab-control-plane \
  cat /var/log/kubernetes/audit.log 2>/dev/null | \
  jq -c 'select(
    (.objectRef.namespace // "") == "users" and
    (.objectRef.resource // "") == "deployments" and
    ((.objectRef.subresource // "") == "scale" or .verb == "patch" or .verb == "update")
  ) | {
    timestamp: .requestReceivedTimestamp,
    user: .user.username,
    verb: .verb,
    name: .objectRef.name,
    subresource: (.objectRef.subresource // ""),
    sourceIP: (.sourceIPs[0] // "unknown")
  }' 2>/dev/null | tail -20 || true)

AUDIT_COUNT=$(echo "$AUDIT_EVENTS" | grep -c "timestamp" 2>/dev/null || echo "0")
[[ -z "$AUDIT_EVENTS" ]] && AUDIT_COUNT=0

{
  echo "═══ Evidencia: Audit Log — scale events en users ═══"
  echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Eventos encontrados: $AUDIT_COUNT"
  echo ""
  if [[ -n "$AUDIT_EVENTS" && "$AUDIT_COUNT" -gt 0 ]]; then
    echo "$AUDIT_EVENTS" | jq '.' 2>/dev/null || echo "$AUDIT_EVENTS"
  else
    echo "(No se encontraron eventos de scale en el audit log)"
  fi
} > "$RESULTS_DIR/audit-scale-events.json"

if [[ "$AUDIT_COUNT" -gt 0 ]]; then
  log_ok "Audit log: $AUDIT_COUNT eventos de scale/update capturados"
else
  log_warn "Audit log: No se encontraron eventos de scale"
fi

# ═════════════════════════════════════════════════════════════════
# 4. Istio metrics — errores 5xx en la comunicación
# ═════════════════════════════════════════════════════════════════
log_info "Capturando Istio proxy logs de user-api..."

ISTIO_LOGS=""
if [[ -n "$USERAPI_POD" ]]; then
  ISTIO_LOGS=$(kubectl logs -n users "$USERAPI_POD" -c istio-proxy \
    --since=5m 2>/dev/null | grep -i "auth-service\|503\|upstream_reset\|no_healthy" | tail -30 || echo "")
fi

ISTIO_ERROR_COUNT=$(echo "$ISTIO_LOGS" | grep -c "." 2>/dev/null || echo "0")
[[ -z "$ISTIO_LOGS" ]] && ISTIO_ERROR_COUNT=0

{
  echo "═══ Evidencia: Istio proxy logs (user-api → auth-service) ═══"
  echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Errores encontrados: $ISTIO_ERROR_COUNT"
  echo ""
  if [[ -n "$ISTIO_LOGS" && "$ISTIO_ERROR_COUNT" -gt 0 ]]; then
    echo "$ISTIO_LOGS"
  else
    echo "(No se detectaron errores de upstream en Istio proxy)"
  fi
} > "$RESULTS_DIR/istio-proxy-errors.txt"

if [[ "$ISTIO_ERROR_COUNT" -gt 0 ]]; then
  log_ok "Istio proxy: $ISTIO_ERROR_COUNT errores de upstream capturados"
else
  log_info "Istio proxy: 0 errores detectados"
fi

# ═════════════════════════════════════════════════════════════════
# Resumen
# ═════════════════════════════════════════════════════════════════
log_step "Resumen de evidencia recolectada"
log_info "user-api error logs:       $ERROR_COUNT"
log_info "Audit scale events:        $AUDIT_COUNT"
log_info "Istio upstream errors:     $ISTIO_ERROR_COUNT"
log_info "Archivos en results/:      $(ls -1 "$RESULTS_DIR" | wc -l | tr -d ' ')"

log_ok "Evidencia recolectada en experiments/SCE-D-001/results/"
