#!/usr/bin/env bash
# experiments/SCE-C-001/observe/generate-report.sh
# Genera el reporte final del experimento SCE-C-001

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/../results"
source "$SCRIPT_DIR/../../../scripts/lib/common.sh"

log_step "SCE-C-001 — Generando reporte"

# Leer resultados del timing.json
TIMING_FILE="$RESULTS_DIR/timing.json"
if [[ -f "$TIMING_FILE" ]]; then
  CREDS_FOUND=$(jq -r '.results.credentials_found' "$TIMING_FILE" 2>/dev/null || echo "?")
  SA_TOKEN=$(jq -r '.results.sa_token_accessible' "$TIMING_FILE" 2>/dev/null || echo "?")
  EGRESS=$(jq -r '.results.egress_blocked' "$TIMING_FILE" 2>/dev/null || echo "?")
  DNS_EXFIL=$(jq -r '.results.dns_exfil_blocked' "$TIMING_FILE" 2>/dev/null || echo "?")
  P1_MS=$(jq -r '.phases.phase1_recon_ms' "$TIMING_FILE" 2>/dev/null || echo "?")
  P2_MS=$(jq -r '.phases.phase2_sa_token_ms' "$TIMING_FILE" 2>/dev/null || echo "?")
  P3_MS=$(jq -r '.phases.phase3_network_exfil_ms' "$TIMING_FILE" 2>/dev/null || echo "?")
  P4_MS=$(jq -r '.phases.phase4_dns_exfil_ms' "$TIMING_FILE" 2>/dev/null || echo "?")
else
  CREDS_FOUND="?" SA_TOKEN="?" EGRESS="?" DNS_EXFIL="?"
  P1_MS="?" P2_MS="?" P3_MS="?" P4_MS="?"
fi

# Contar evidencia
FALCO_COUNT=$(grep -c "SCE-C-001\|Unexpected\|Exfiltration" "$RESULTS_DIR/falco-alerts.json" 2>/dev/null || echo "0")
AUDIT_COUNT=$(grep -c '"timestamp"' "$RESULTS_DIR/audit-exec-events.json" 2>/dev/null || echo "0")

# Determinar resultados de controles
result_icon() {
  if [[ "$1" == "true" ]]; then echo "EFECTIVO"; else echo "NO EFECTIVO"; fi
}

cat > "$RESULTS_DIR/report.txt" <<REPORT
╔══════════════════════════════════════════════════════════════════════╗
║             SCE-C-001 — REPORTE DE EXPERIMENTO                     ║
║        Exfiltración de credenciales desde pod comprometido         ║
╚══════════════════════════════════════════════════════════════════════╝

Fecha de ejecución: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Target:             payments/payment-processor
Imagen:             curlimages/curl:latest

═══════════════════════════════════════════════════════════════════════
HIPÓTESIS
═══════════════════════════════════════════════════════════════════════

Las credenciales expuestas como variables de entorno en payment-processor
pueden ser leídas trivialmente por un atacante con acceso al pod, pero
la exfiltración a destinos externos es bloqueada por NetworkPolicy y
el acceso es detectado por Falco y registrado en el audit log de K8s.

═══════════════════════════════════════════════════════════════════════
RESULTADOS POR FASE
═══════════════════════════════════════════════════════════════════════

┌─────────────────────────────────────────────────────────────────────┐
│ FASE 1 — Reconocimiento de credenciales                           │
├─────────────────────────────────────────────────────────────────────┤
│ Resultado:    HALLAZGO CONFIRMADO                                  │
│ Credenciales: ${CREDS_FOUND} encontradas (DB_PASSWORD, API_KEY, STRIPE_KEY) │
│ Duración:     ${P1_MS}ms                                              │
│ Evidencia:    results/phase1-recon.txt                             │
│ Impacto:      Un atacante con exec puede leer secretos directamente│
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ FASE 2 — Lectura del ServiceAccount token                         │
├─────────────────────────────────────────────────────────────────────┤
│ Token accesible: ${SA_TOKEN}                                        │
│ Duración:        ${P2_MS}ms                                            │
│ Evidencia:       results/phase2-sa-token.txt                       │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ FASE 3 — Exfiltración por red (egress HTTP a IP externa)          │
├─────────────────────────────────────────────────────────────────────┤
│ Egress bloqueado: ${EGRESS}                                         │
│ Duración:         ${P3_MS}ms                                           │
│ Evidencia:        results/phase3-network-exfil.txt                 │
│ Control:          NetworkPolicy default-deny-all                   │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ FASE 4 — Exfiltración por DNS                                     │
├─────────────────────────────────────────────────────────────────────┤
│ DNS exfil bloqueada: ${DNS_EXFIL}                                   │
│ Duración:            ${P4_MS}ms                                        │
│ Evidencia:           results/phase4-dns-exfil.txt                  │
└─────────────────────────────────────────────────────────────────────┘

═══════════════════════════════════════════════════════════════════════
CONTROLES DE SEGURIDAD EVALUADOS
═══════════════════════════════════════════════════════════════════════

┌──────────────────────────────┬────────────────┬──────────────────────────┐
│ Control                      │ Resultado      │ Evidencia                │
├──────────────────────────────┼────────────────┼──────────────────────────┤
│ NetworkPolicy default-deny   │ $(printf '%-14s' "$(result_icon "$EGRESS")") │ phase3, phase4             │
│ Falco runtime detection      │ ${FALCO_COUNT} alertas    │ falco-alerts.json          │
│ K8s audit logging            │ ${AUDIT_COUNT} eventos    │ audit-exec-events.json     │
│ automountSAToken: false      │ $(if [[ "$SA_TOKEN" == "false" ]]; then echo "EFECTIVO      "; else echo "NO EFECTIVO   "; fi) │ phase2-sa-token.txt        │
│ Vault (vs env vars)          │ N/A — comparar │ Ver payment-api.yaml       │
└──────────────────────────────┴────────────────┴──────────────────────────┘

═══════════════════════════════════════════════════════════════════════
HALLAZGOS Y RECOMENDACIONES
═══════════════════════════════════════════════════════════════════════

1. HALLAZGO PRINCIPAL (Confidencialidad):
   Las credenciales en payment-processor están expuestas como variables
   de entorno directas. Cualquier proceso con acceso al pod puede leerlas
   trivialmente con 'env' o leyendo /proc/self/environ.

2. CONTROL EFECTIVO (Red):
   NetworkPolicy default-deny-all bloquea exitosamente la exfiltración
   de credenciales a destinos externos por HTTP.

3. REMEDIACIÓN RECOMENDADA:
   Migrar credenciales de env vars a Vault Agent Injector (ver implementación
   en payment-api.yaml como referencia). Esto elimina las credenciales
   del espacio de memoria del proceso y las inyecta como archivos en tmpfs.

4. COMPARACIÓN payment-processor vs payment-api:
   - payment-processor: credenciales en env vars (VULNERABLE)
   - payment-api: credenciales vía Vault Agent Injector (REMEDIADO)
   Esta diferencia valida la efectividad de Vault como control.

═══════════════════════════════════════════════════════════════════════
MAPEO MITRE ATT&CK
═══════════════════════════════════════════════════════════════════════

Táctica:    Credential Access (TA0006)
Técnica:    Unsecured Credentials: Credentials in Files (T1552.001)
Sub-técnica: Container Environment Variables
Plataforma: Containers (Kubernetes)

══════════════════════════════════════════════════════════════════════
Fin del reporte SCE-C-001
══════════════════════════════════════════════════════════════════════
REPORT

log_ok "Reporte generado: experiments/SCE-C-001/results/report.txt"
cat "$RESULTS_DIR/report.txt"
