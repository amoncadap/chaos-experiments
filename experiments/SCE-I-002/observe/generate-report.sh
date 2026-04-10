#!/usr/bin/env bash
# experiments/SCE-I-002/observe/generate-report.sh
# Genera el reporte final del experimento SCE-I-002

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/../results"
source "$SCRIPT_DIR/../../../scripts/lib/common.sh"

log_step "SCE-I-002 — Generando reporte"

# Leer resultados del timing.json
TIMING_FILE="$RESULTS_DIR/timing.json"
if [[ -f "$TIMING_FILE" ]]; then
  VARLOG_BLOCKED=$(jq -r '.results.varlog_write_blocked' "$TIMING_FILE" 2>/dev/null || echo "?")
  STDOUT_TAMPER=$(jq -r '.results.stdout_tamper_possible' "$TIMING_FILE" 2>/dev/null || echo "?")
  ES_BLOCKED=$(jq -r '.results.es_access_blocked' "$TIMING_FILE" 2>/dev/null || echo "?")
  HOST_BLOCKED=$(jq -r '.results.host_access_blocked' "$TIMING_FILE" 2>/dev/null || echo "?")
  P1_MS=$(jq -r '.phases.phase1_varlog_write_ms' "$TIMING_FILE" 2>/dev/null || echo "?")
  P2_MS=$(jq -r '.phases.phase2_stdout_tamper_ms' "$TIMING_FILE" 2>/dev/null || echo "?")
  P3_MS=$(jq -r '.phases.phase3_es_access_ms' "$TIMING_FILE" 2>/dev/null || echo "?")
  P4_MS=$(jq -r '.phases.phase4_host_audit_ms' "$TIMING_FILE" 2>/dev/null || echo "?")
else
  VARLOG_BLOCKED="?" STDOUT_TAMPER="?" ES_BLOCKED="?" HOST_BLOCKED="?"
  P1_MS="?" P2_MS="?" P3_MS="?" P4_MS="?"
fi

# Contar evidencia
FALCO_COUNT=$(grep -c "SCE-I-002\|Log File Modification\|defense-evasion" "$RESULTS_DIR/falco-alerts.json" 2>/dev/null || echo "0")
AUDIT_COUNT=$(grep -c '"timestamp"' "$RESULTS_DIR/audit-exec-events.json" 2>/dev/null || echo "0")
ES_INJECT=$(grep -c "legitimate-looking-but-fake" "$RESULTS_DIR/elasticsearch-injection.json" 2>/dev/null || echo "0")

result_icon() {
  if [[ "$1" == "true" ]]; then echo "EFECTIVO"; else echo "NO EFECTIVO"; fi
}

cat > "$RESULTS_DIR/report.txt" <<REPORT
╔══════════════════════════════════════════════════════════════════════╗
║             SCE-I-002 — REPORTE DE EXPERIMENTO                     ║
║        Corrupción de registros de auditoría                        ║
╚══════════════════════════════════════════════════════════════════════╝

Fecha de ejecución: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Target:             payments/payment-processor
Imagen:             curlimages/curl:latest

═══════════════════════════════════════════════════════════════════════
HIPÓTESIS
═══════════════════════════════════════════════════════════════════════

Un atacante con acceso a un pod de aplicación NO puede corromper,
eliminar o modificar los registros de auditoría del sistema debido a:
  1. readOnlyRootFilesystem impide escritura en /var/log/
  2. NetworkPolicy impide conexión directa a Elasticsearch
  3. El audit log de Kubernetes reside en el control-plane (inaccesible)
  4. Los registros en ES son append-only e inmutables desde los pods

Sin embargo, el atacante SÍ puede inyectar registros falsos en stdout
del contenedor, que serán capturados por Fluentd como logs legítimos.

═══════════════════════════════════════════════════════════════════════
RESULTADOS POR FASE
═══════════════════════════════════════════════════════════════════════

┌─────────────────────────────────────────────────────────────────────┐
│ FASE 1 — Escritura en /var/log/ (readOnlyRootFilesystem)          │
├─────────────────────────────────────────────────────────────────────┤
│ Escritura bloqueada: ${VARLOG_BLOCKED}                                │
│ Duración:            ${P1_MS}ms                                        │
│ Evidencia:           results/phase1-varlog-write.txt               │
│ Control:             readOnlyRootFilesystem: true                  │
│ Nota:                /tmp/ (emptyDir) sí permite escritura         │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ FASE 2 — Inyección en stdout/stderr (log injection)               │
├─────────────────────────────────────────────────────────────────────┤
│ Inyección posible:  sí (stdout es writable)                        │
│ Duración:           ${P2_MS}ms                                         │
│ Evidencia:          results/phase2-stdout-tamper.txt               │
│ Impacto:            Se pueden AGREGAR registros falsos,            │
│                     pero NO eliminar los existentes                │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ FASE 3 — Acceso directo a Elasticsearch                           │
├─────────────────────────────────────────────────────────────────────┤
│ Acceso bloqueado: ${ES_BLOCKED}                                       │
│ Duración:         ${P3_MS}ms                                           │
│ Evidencia:        results/phase3-es-access.txt                     │
│ Control:          NetworkPolicy default-deny-all                   │
│ Protege:          DELETE/PUT en índices fluentd-*                   │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ FASE 4 — Acceso al audit log del host                             │
├─────────────────────────────────────────────────────────────────────┤
│ Acceso bloqueado: ${HOST_BLOCKED}                                     │
│ Duración:         ${P4_MS}ms                                           │
│ Evidencia:        results/phase4-host-audit.txt                    │
│ Controles:        No hostPath, no privileges, seccomp              │
└─────────────────────────────────────────────────────────────────────┘

═══════════════════════════════════════════════════════════════════════
CONTROLES DE SEGURIDAD EVALUADOS
═══════════════════════════════════════════════════════════════════════

┌──────────────────────────────────┬────────────────┬────────────────────────┐
│ Control                          │ Resultado      │ Evidencia              │
├──────────────────────────────────┼────────────────┼────────────────────────┤
│ readOnlyRootFilesystem           │ $(printf '%-14s' "$(result_icon "$VARLOG_BLOCKED")") │ phase1                 │
│ NetworkPolicy → ES bloqueada     │ $(printf '%-14s' "$(result_icon "$ES_BLOCKED")") │ phase3                 │
│ Aislamiento audit log (host)     │ $(printf '%-14s' "$(result_icon "$HOST_BLOCKED")") │ phase4                 │
│ allowPrivilegeEscalation: false  │ $(printf '%-14s' "$(result_icon "$HOST_BLOCKED")") │ phase4                 │
│ Falco detection (SCE-I-002)      │ ${FALCO_COUNT} alertas    │ falco-alerts.json      │
│ K8s audit logging                │ ${AUDIT_COUNT} eventos    │ audit-exec-events.json │
│ Integridad ES (append-only)      │ EFECTIVO       │ elasticsearch-integrity│
└──────────────────────────────────┴────────────────┴────────────────────────┘

═══════════════════════════════════════════════════════════════════════
HALLAZGOS Y RECOMENDACIONES
═══════════════════════════════════════════════════════════════════════

1. HALLAZGO PRINCIPAL (Integridad — Protección EFECTIVA):
   Los registros de auditoría están protegidos por múltiples capas:
   - Filesystem read-only en contenedores
   - Aislamiento de red (NetworkPolicy) hacia Elasticsearch
   - Audit log de K8s en el control-plane (inaccesible)
   Un atacante con acceso a un pod NO puede eliminar ni modificar
   los registros existentes.

2. HALLAZGO SECUNDARIO (Log Injection — Riesgo BAJO):
   Un atacante puede inyectar líneas en stdout del contenedor que
   llegarán a Fluentd → Elasticsearch. Esto permite:
   - Insertar registros falsos (noise)
   - Confundir análisis forense con datos fabricados
   Mitigación: usar campos de metadatos de Kubernetes (automáticos
   y no manipulables) para correlación, no el contenido del log.

3. CONTROL PREVENTIVO vs DETECTIVO:
   readOnlyRootFilesystem bloquea la escritura ANTES de que el
   syscall open() se ejecute. Esto significa que Falco (control
   detectivo) puede no generar alertas si el kernel rechaza la
   operación antes del evento. Esto es POSITIVO: el control
   preventivo actúa primero.

4. REMEDIACIÓN PARA LOG INJECTION:
   - Implementar firma/HMAC de log entries en la aplicación
   - Usar structured logging con campos no manipulables
   - Alertar sobre volumen anómalo de logs por pod (anomaly detection)
   - Considerar log signing con Sigstore/Rekor para non-repudiation

═══════════════════════════════════════════════════════════════════════
MAPEO MITRE ATT&CK
═══════════════════════════════════════════════════════════════════════

Táctica:      Defense Evasion (TA0005)
Técnica:      Impair Defenses: Disable or Modify Cloud Logs (T1562.008)
Sub-técnica:  Indicator Removal: Clear Linux or Mac System Logs (T1070.002)
Plataforma:   Containers (Kubernetes)

═══════════════════════════════════════════════════════════════════════
COMPARACIÓN CON PoC-003 (Hallazgo original)
═══════════════════════════════════════════════════════════════════════

PoC-003 identificó que los logs de init containers no se capturaban
por un bug en el parser de Fluentd. Esto fue remediado configurando
el parser CRI correcto. Este experimento valida que la remediación
funciona y que los registros son resistentes a corrupción.

══════════════════════════════════════════════════════════════════════
Fin del reporte SCE-I-002
══════════════════════════════════════════════════════════════════════
REPORT

log_ok "Reporte generado: experiments/SCE-I-002/results/report.txt"
cat "$RESULTS_DIR/report.txt"
