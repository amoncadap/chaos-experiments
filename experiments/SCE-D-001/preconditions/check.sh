#!/usr/bin/env bash
# experiments/SCE-D-001/preconditions/check.sh
# Valida que el entorno esté listo para ejecutar SCE-D-001
# (Agotamiento del IDP — fail-secure behavior)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../scripts/lib/common.sh"

log_step "SCE-D-001 — Verificación de precondiciones"

# 1. auth-service corriendo con 1 réplica
log_info "Verificando auth-service..."
AUTH_REPLICAS=$(kubectl get deploy auth-service -n users \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "$AUTH_REPLICAS" -ge 1 ]]; then
  log_ok "Precondición OK: auth-service tiene ${AUTH_REPLICAS} réplica(s) Ready"
else
  log_error "Precondición FALLIDA: auth-service no tiene réplicas Ready (${AUTH_REPLICAS})"
fi

# 2. user-api corriendo
assert_precondition "user-api corriendo en users" \
  kubectl get deploy user-api -n users

# 3. user-api tiene JWT cache habilitado
log_info "Verificando configuración JWT cache en user-api..."
CACHE_ENABLED=$(kubectl get deploy user-api -n users \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="JWT_CACHE_ENABLED")].value}' 2>/dev/null)
CACHE_TTL=$(kubectl get deploy user-api -n users \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="JWT_CACHE_TTL_SECONDS")].value}' 2>/dev/null)
if [[ "$CACHE_ENABLED" == "true" ]]; then
  log_ok "Precondición OK: JWT cache habilitado (TTL: ${CACHE_TTL}s)"
else
  log_warn "JWT cache no habilitado en user-api (CACHE_ENABLED=${CACHE_ENABLED})"
fi

# 4. ConfigMap user-api-config existe
assert_precondition "ConfigMap user-api-config en users" \
  kubectl get configmap user-api-config -n users

# 5. auth-service responde (health check baseline via python3 en app container)
log_info "Verificando que auth-service responde..."
AUTH_POD=$(kubectl get pods -n users -l app=auth-service \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$AUTH_POD" ]]; then
  AUTH_CODE=$(kubectl exec -n users "$AUTH_POD" -c auth-service \
    -- python3 -c "
import urllib.request, socket
socket.setdefaulttimeout(5)
try:
    r = urllib.request.urlopen('http://localhost:80/get')
    print(r.status)
except Exception:
    print(0)
" 2>/dev/null || echo "0")
  if [[ "$AUTH_CODE" == "200" ]]; then
    log_ok "Precondición OK: auth-service responde correctamente"
  else
    log_warn "auth-service no responde al health check (HTTP $AUTH_CODE)"
  fi
fi

# 6. user-api puede alcanzar auth-service (conectividad intra-namespace via mTLS)
log_info "Verificando conectividad user-api → auth-service..."
USERAPI_POD=$(kubectl get pods -n users -l app=user-api \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$USERAPI_POD" ]]; then
  CONN_CODE=$(kubectl exec -n users "$USERAPI_POD" -c user-api \
    -- python3 -c "
import urllib.request, socket
socket.setdefaulttimeout(5)
try:
    r = urllib.request.urlopen('http://auth-service.users.svc.cluster.local/get')
    print(r.status)
except Exception:
    print(0)
" 2>/dev/null || echo "0")
  if [[ "$CONN_CODE" == "200" ]]; then
    log_ok "Precondición OK: user-api → auth-service conectividad OK"
  else
    log_warn "user-api no puede alcanzar auth-service (HTTP $CONN_CODE)"
  fi
fi

# 7. mTLS STRICT en users namespace
check_mtls users

log_ok "Todas las precondiciones verificadas para SCE-D-001"
