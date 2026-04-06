#!/usr/bin/env bash
# experiments/SCE-D-001/rollback/cleanup.sh
# Restaura auth-service después del experimento SCE-D-001

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../scripts/lib/common.sh"

TARGET_NS="users"
AUTH_DEPLOY="auth-service"

log_step "SCE-D-001 — Rollback y limpieza"

# ═════════════════════════════════════════════════════════════════
# CRÍTICO: Restaurar auth-service a 1 réplica
# ═════════════════════════════════════════════════════════════════
log_info "Restaurando auth-service a 1 réplica..."

CURRENT_REPLICAS=$(kubectl get deploy "$AUTH_DEPLOY" -n "$TARGET_NS" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")

if [[ "$CURRENT_REPLICAS" == "0" ]]; then
  kubectl scale deploy/"$AUTH_DEPLOY" --replicas=1 -n "$TARGET_NS"
  log_info "Esperando a que auth-service esté Ready..."
  kubectl wait --for=condition=Available deploy/"$AUTH_DEPLOY" \
    -n "$TARGET_NS" --timeout=60s 2>/dev/null || true

  READY=$(kubectl get deploy "$AUTH_DEPLOY" -n "$TARGET_NS" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [[ "$READY" -ge 1 ]]; then
    log_ok "auth-service restaurado: ${READY} réplica(s) Ready"
  else
    log_warn "auth-service: réplicas no Ready aún — verificar manualmente"
  fi
else
  log_ok "auth-service ya tiene ${CURRENT_REPLICAS} réplica(s) configurada(s)"
fi

# Verificar que user-api sigue corriendo
USERAPI_READY=$(kubectl get deploy user-api -n "$TARGET_NS" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "$USERAPI_READY" -ge 1 ]]; then
  log_ok "user-api: ${USERAPI_READY} réplica(s) Running"
else
  log_warn "user-api: no tiene réplicas Ready — verificar manualmente"
fi

# Verificar conectividad restaurada
log_info "Verificando conectividad user-api → auth-service..."
USERAPI_POD=$(kubectl get pods -n "$TARGET_NS" -l app=user-api \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$USERAPI_POD" ]]; then
  HTTP_CODE=$(kubectl exec -n "$TARGET_NS" "$USERAPI_POD" -c user-api \
    -- python3 -c "
import urllib.request, socket
socket.setdefaulttimeout(5)
try:
    r = urllib.request.urlopen('http://auth-service.users.svc.cluster.local/get')
    print(r.status)
except Exception:
    print(0)
" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" == "200" ]]; then
    log_ok "Conectividad restaurada: user-api → auth-service HTTP $HTTP_CODE"
  else
    log_warn "Conectividad no restaurada: HTTP $HTTP_CODE — puede necesitar más tiempo"
  fi
fi

log_ok "Rollback completado — auth-service restaurado"
