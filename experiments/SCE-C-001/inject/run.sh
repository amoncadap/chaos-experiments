#!/usr/bin/env bash
# experiments/SCE-C-001/inject/run.sh
# Inyección del experimento SCE-C-001: Exfiltración de credenciales
#
# Simula un atacante con ejecución de comandos en payment-processor.
# 4 fases: reconocimiento → SA token → exfil red → exfil DNS

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/../results"
source "$SCRIPT_DIR/../../../scripts/lib/common.sh"

TARGET_DEPLOY="payment-processor"
TARGET_NS="payments"
TARGET_CONTAINER="payment-processor"

log_step "SCE-C-001 — Fase de inyección"

# ═════════════════════════════════════════════════════════════════
# FASE 1: Reconocimiento — Lectura de variables de entorno
# ═════════════════════════════════════════════════════════════════
log_step "Fase 1 — Reconocimiento de credenciales (env vars)"

record_timing PHASE1_START

log_info "Ejecutando: kubectl exec → env | grep PASSWORD|KEY|SECRET"
PHASE1_EXIT=0
PHASE1_OUTPUT=$(kubectl exec -n "$TARGET_NS" "deploy/$TARGET_DEPLOY" \
  -c "$TARGET_CONTAINER" -- env 2>&1 | grep -E "PASSWORD|KEY|SECRET") || PHASE1_EXIT=$?

record_timing PHASE1_END

{
  echo "═══ FASE 1: Reconocimiento de credenciales ═══"
  echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Comando: kubectl exec -n $TARGET_NS deploy/$TARGET_DEPLOY -c $TARGET_CONTAINER -- env"
  echo "Exit code: $PHASE1_EXIT"
  echo "Duración: $(elapsed_ms "$PHASE1_START" "$PHASE1_END")ms"
  echo ""
  echo "─── Credenciales encontradas ───"
  echo "$PHASE1_OUTPUT"
  echo ""
  if [[ -n "$PHASE1_OUTPUT" ]]; then
    echo "RESULTADO: HALLAZGO CONFIRMADO — Credenciales visibles como env vars"
    echo "IMPACTO: Un atacante con acceso al pod puede leer DB_PASSWORD, API_KEY, STRIPE_KEY"
  else
    echo "RESULTADO: No se encontraron credenciales en env vars"
  fi
} > "$RESULTS_DIR/phase1-recon.txt"

if [[ -n "$PHASE1_OUTPUT" ]]; then
  log_ok "Fase 1: $(echo "$PHASE1_OUTPUT" | wc -l | tr -d ' ') credenciales encontradas (hallazgo confirmado)"
else
  log_warn "Fase 1: No se encontraron credenciales en env vars"
fi

# ═════════════════════════════════════════════════════════════════
# FASE 2: Lectura del ServiceAccount token
# ═════════════════════════════════════════════════════════════════
log_step "Fase 2 — Lectura del ServiceAccount token"

record_timing PHASE2_START

log_info "Ejecutando: kubectl exec → cat /run/secrets/kubernetes.io/serviceaccount/token"
PHASE2_EXIT=0
PHASE2_OUTPUT=$(kubectl exec -n "$TARGET_NS" "deploy/$TARGET_DEPLOY" \
  -c "$TARGET_CONTAINER" -- cat /run/secrets/kubernetes.io/serviceaccount/token 2>&1) || PHASE2_EXIT=$?

record_timing PHASE2_END

# Determinar si el token fue accesible
SA_TOKEN_ACCESSIBLE="false"
if [[ $PHASE2_EXIT -eq 0 && ! "$PHASE2_OUTPUT" =~ "No such file" && ! "$PHASE2_OUTPUT" =~ "Permission denied" ]]; then
  SA_TOKEN_ACCESSIBLE="true"
fi

{
  echo "═══ FASE 2: Lectura del ServiceAccount token ═══"
  echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Comando: kubectl exec → cat /run/secrets/.../token"
  echo "Exit code: $PHASE2_EXIT"
  echo "Duración: $(elapsed_ms "$PHASE2_START" "$PHASE2_END")ms"
  echo ""
  echo "─── Output ───"
  echo "$PHASE2_OUTPUT" | head -5
  echo ""
  if [[ "$SA_TOKEN_ACCESSIBLE" == "true" ]]; then
    echo "RESULTADO: TOKEN ACCESIBLE — automountServiceAccountToken activo o no deshabilitado"
    echo "RIESGO: El atacante puede usar el token para interactuar con la API de Kubernetes"
  else
    echo "RESULTADO: TOKEN NO ACCESIBLE — automountServiceAccountToken deshabilitado"
    echo "CONTROL EFECTIVO: El pod no monta el token del SA por defecto"
  fi
} > "$RESULTS_DIR/phase2-sa-token.txt"

if [[ "$SA_TOKEN_ACCESSIBLE" == "true" ]]; then
  log_warn "Fase 2: SA token ACCESIBLE (riesgo de escalación)"
else
  log_ok "Fase 2: SA token no accesible (control efectivo)"
fi

# ═════════════════════════════════════════════════════════════════
# FASE 3: Intento de exfiltración por red (egress externo)
# ═════════════════════════════════════════════════════════════════
log_step "Fase 3 — Exfiltración por red (egress a IP externa)"

record_timing PHASE3_START

log_info "Ejecutando: kubectl exec → curl http://1.1.1.1 (NetworkPolicy debe bloquear)"
PHASE3_EXIT=0
PHASE3_OUTPUT=$(kubectl exec -n "$TARGET_NS" "deploy/$TARGET_DEPLOY" \
  -c "$TARGET_CONTAINER" -- curl -sf --max-time 5 http://1.1.1.1/ 2>&1) || PHASE3_EXIT=$?

record_timing PHASE3_END

EGRESS_BLOCKED="true"
if [[ $PHASE3_EXIT -eq 0 ]]; then
  EGRESS_BLOCKED="false"
fi

{
  echo "═══ FASE 3: Exfiltración por red (egress externo) ═══"
  echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Comando: curl -sf --max-time 5 http://1.1.1.1/"
  echo "Exit code: $PHASE3_EXIT"
  echo "Duración: $(elapsed_ms "$PHASE3_START" "$PHASE3_END")ms"
  echo ""
  echo "─── Output ───"
  echo "$PHASE3_OUTPUT" | head -10
  echo ""
  if [[ "$EGRESS_BLOCKED" == "true" ]]; then
    echo "RESULTADO: EGRESS BLOQUEADO — NetworkPolicy default-deny-all efectiva"
    echo "CONTROL EFECTIVO: El atacante no puede enviar credenciales a un servidor externo"
  else
    echo "RESULTADO: ⚠ EGRESS PERMITIDO — NetworkPolicy NO bloqueó la conexión"
    echo "HALLAZGO: Las credenciales podrían ser exfiltradas por red"
  fi
} > "$RESULTS_DIR/phase3-network-exfil.txt"

if [[ "$EGRESS_BLOCKED" == "true" ]]; then
  log_ok "Fase 3: Egress BLOQUEADO por NetworkPolicy (exit code: $PHASE3_EXIT)"
else
  log_warn "Fase 3: ⚠ Egress PERMITIDO — NetworkPolicy no efectiva"
fi

# ═════════════════════════════════════════════════════════════════
# FASE 4: Intento de exfiltración por DNS
# ═════════════════════════════════════════════════════════════════
log_step "Fase 4 — Exfiltración por DNS (resolver externo)"

record_timing PHASE4_START

log_info "Ejecutando: kubectl exec → curl http://ifconfig.me (DNS + egress)"
PHASE4_EXIT=0
PHASE4_OUTPUT=$(kubectl exec -n "$TARGET_NS" "deploy/$TARGET_DEPLOY" \
  -c "$TARGET_CONTAINER" -- curl -sf --max-time 5 http://ifconfig.me 2>&1) || PHASE4_EXIT=$?

record_timing PHASE4_END

DNS_EXFIL_BLOCKED="true"
if [[ $PHASE4_EXIT -eq 0 ]]; then
  DNS_EXFIL_BLOCKED="false"
fi

{
  echo "═══ FASE 4: Exfiltración por DNS ═══"
  echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Comando: curl -sf --max-time 5 http://ifconfig.me"
  echo "Exit code: $PHASE4_EXIT"
  echo "Duración: $(elapsed_ms "$PHASE4_START" "$PHASE4_END")ms"
  echo ""
  echo "─── Output ───"
  echo "$PHASE4_OUTPUT" | head -10
  echo ""
  if [[ "$DNS_EXFIL_BLOCKED" == "true" ]]; then
    echo "RESULTADO: DNS EXFILTRACIÓN BLOQUEADA"
    echo "CONTROL EFECTIVO: La resolución DNS externa y/o egress HTTP bloqueados"
  else
    echo "RESULTADO: ⚠ DNS EXFILTRACIÓN POSIBLE — se obtuvo respuesta de ifconfig.me"
    echo "HALLAZGO: Un atacante podría usar DNS tunneling para exfiltrar datos"
  fi
} > "$RESULTS_DIR/phase4-dns-exfil.txt"

if [[ "$DNS_EXFIL_BLOCKED" == "true" ]]; then
  log_ok "Fase 4: DNS exfiltración BLOQUEADA (exit code: $PHASE4_EXIT)"
else
  log_warn "Fase 4: ⚠ DNS exfiltración posible"
fi

# ═════════════════════════════════════════════════════════════════
# Guardar timing consolidado
# ═════════════════════════════════════════════════════════════════
cat > "$RESULTS_DIR/timing.json" <<EOF
{
  "experiment": "SCE-C-001",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "phases": {
    "phase1_recon_ms": $(elapsed_ms "$PHASE1_START" "$PHASE1_END"),
    "phase2_sa_token_ms": $(elapsed_ms "$PHASE2_START" "$PHASE2_END"),
    "phase3_network_exfil_ms": $(elapsed_ms "$PHASE3_START" "$PHASE3_END"),
    "phase4_dns_exfil_ms": $(elapsed_ms "$PHASE4_START" "$PHASE4_END")
  },
  "results": {
    "credentials_found": $(echo "$PHASE1_OUTPUT" | wc -l | tr -d ' '),
    "sa_token_accessible": $SA_TOKEN_ACCESSIBLE,
    "egress_blocked": $EGRESS_BLOCKED,
    "dns_exfil_blocked": $DNS_EXFIL_BLOCKED
  }
}
EOF

log_ok "Inyección completada — resultados en experiments/SCE-C-001/results/"
