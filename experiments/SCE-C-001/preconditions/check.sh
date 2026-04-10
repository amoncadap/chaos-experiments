#!/usr/bin/env bash
# experiments/SCE-C-001/preconditions/check.sh
# Valida que el entorno esté listo para ejecutar SCE-C-001

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../scripts/lib/common.sh"

log_step "SCE-C-001 — Verificación de precondiciones"

# 1. NetworkPolicy default-deny-all en payments
assert_precondition "NetworkPolicy default-deny-all en payments" \
  kubectl get networkpolicy default-deny-all -n payments

# 2. Falco DaemonSet corriendo en todos los nodos
check_falco

# 3. payment-processor corriendo con credenciales en env vars
assert_precondition "payment-processor corriendo en payments" \
  kubectl get deploy payment-processor -n payments

log_info "Verificando credenciales como env vars en payment-processor..."
CREDS=$(kubectl exec -n payments deploy/payment-processor -c payment-processor \
  -- env 2>/dev/null | grep -cE "DB_PASSWORD|API_KEY|STRIPE_KEY" || true)
if [[ "$CREDS" -ge 2 ]]; then
  log_ok "Precondición OK: payment-processor tiene ${CREDS} credenciales como env vars"
else
  log_error "Precondición FALLIDA: payment-processor no tiene credenciales como env vars (encontradas: ${CREDS})"
fi

# 4. Elasticsearch accesible
log_info "Verificando Elasticsearch..."
ES_HEALTH=$(kubectl exec -n logging elasticsearch-master-0 -- \
  curl -sf 'http://localhost:9200/_cluster/health' 2>/dev/null | \
  jq -r '.status' 2>/dev/null || echo "unreachable")
if [[ "$ES_HEALTH" != "unreachable" ]]; then
  log_ok "Precondición OK: Elasticsearch accesible (status: ${ES_HEALTH})"
else
  log_warn "Elasticsearch no accesible — evidencia en ES no estará disponible"
fi

# 5. Falco con reglas SCE-C-001 cargadas
log_info "Verificando reglas Falco SCE-C-001..."
FALCO_POD=$(kubectl get pods -n infra -l app.kubernetes.io/name=falco \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$FALCO_POD" ]]; then
  RULES_LOADED=$(kubectl logs -n infra "$FALCO_POD" -c falco 2>/dev/null | \
    grep -c "sce-custom-rules" || true)
  if [[ "$RULES_LOADED" -ge 1 ]]; then
    log_ok "Precondición OK: Reglas SCE custom cargadas en Falco"
  else
    log_warn "No se detectaron reglas SCE custom en los logs de Falco"
  fi
fi

log_ok "Todas las precondiciones verificadas para SCE-C-001"
