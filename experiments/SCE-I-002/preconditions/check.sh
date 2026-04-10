#!/usr/bin/env bash
# experiments/SCE-I-002/preconditions/check.sh
# Valida que el entorno esté listo para ejecutar SCE-I-002
# (Corrupción de registros de auditoría)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../scripts/lib/common.sh"

log_step "SCE-I-002 — Verificación de precondiciones"

# 1. Falco DaemonSet con regla SCE-I-002
check_falco

log_info "Verificando regla Falco SCE-I-002 cargada..."
FALCO_POD=$(kubectl get pods -n infra -l app.kubernetes.io/name=falco \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$FALCO_POD" ]]; then
  RULES_OK=$(kubectl logs -n infra "$FALCO_POD" -c falco 2>/dev/null | \
    grep -c "sce-custom-rules" || true)
  if [[ "$RULES_OK" -ge 1 ]]; then
    log_ok "Precondición OK: Reglas SCE custom cargadas (incluye SCE-I-002)"
  else
    log_warn "No se detectaron reglas SCE custom en Falco"
  fi
fi

# 2. Fluentd DaemonSet corriendo en todos los nodos
log_info "Verificando Fluentd DaemonSet..."
FLUENTD_DESIRED=$(kubectl get daemonset fluentd -n logging \
  -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
FLUENTD_READY=$(kubectl get daemonset fluentd -n logging \
  -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
if [[ "$FLUENTD_DESIRED" -gt 0 && "$FLUENTD_DESIRED" == "$FLUENTD_READY" ]]; then
  log_ok "Precondición OK: Fluentd DaemonSet ${FLUENTD_READY}/${FLUENTD_DESIRED} nodos"
else
  log_error "Precondición FALLIDA: Fluentd DaemonSet ${FLUENTD_READY}/${FLUENTD_DESIRED}"
fi

# 3. Elasticsearch accesible
log_info "Verificando Elasticsearch..."
ES_HEALTH=$(kubectl exec -n logging elasticsearch-master-0 -- \
  curl -sf 'http://localhost:9200/_cluster/health' 2>/dev/null | \
  jq -r '.status' 2>/dev/null || echo "unreachable")
if [[ "$ES_HEALTH" != "unreachable" ]]; then
  log_ok "Precondición OK: Elasticsearch accesible (status: ${ES_HEALTH})"
else
  log_error "Precondición FALLIDA: Elasticsearch no accesible"
fi

# 4. Pods de aplicación corriendo con readOnlyRootFilesystem
log_info "Verificando pods de aplicación en payments..."
assert_precondition "payment-processor corriendo en payments" \
  kubectl get deploy payment-processor -n payments

RO_FS=$(kubectl get deploy payment-processor -n payments \
  -o jsonpath='{.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem}' 2>/dev/null)
if [[ "$RO_FS" == "true" ]]; then
  log_ok "Precondición OK: payment-processor tiene readOnlyRootFilesystem: true"
else
  log_warn "payment-processor NO tiene readOnlyRootFilesystem: true (actual: ${RO_FS})"
fi

# 5. Audit logging habilitado en kube-apiserver
log_info "Verificando audit logging en kube-apiserver..."
AUDIT_ENABLED=$(docker exec sce-lab-control-plane \
  cat /etc/kubernetes/manifests/kube-apiserver.yaml 2>/dev/null | \
  grep -c "audit-log-path" || true)
if [[ "$AUDIT_ENABLED" -ge 1 ]]; then
  log_ok "Precondición OK: Audit logging habilitado en kube-apiserver"
else
  log_warn "Audit logging no detectado en kube-apiserver"
fi

# 6. Audit log existe y tiene contenido
AUDIT_SIZE=$(docker exec sce-lab-control-plane \
  wc -l /var/log/kubernetes/audit.log 2>/dev/null | awk '{print $1}' || echo "0")
if [[ "$AUDIT_SIZE" -gt 0 ]]; then
  log_ok "Precondición OK: Audit log tiene ${AUDIT_SIZE} líneas"
else
  log_warn "Audit log vacío o no accesible"
fi

log_ok "Todas las precondiciones verificadas para SCE-I-002"
