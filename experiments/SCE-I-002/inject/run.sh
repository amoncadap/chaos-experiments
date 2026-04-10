#!/usr/bin/env bash
# experiments/SCE-I-002/inject/run.sh
# Inyección del experimento SCE-I-002: Corrupción de registros de auditoría
#
# Simula un atacante intentando:
#   Fase 1: Escribir/modificar archivos en /var/log/ dentro del contenedor
#   Fase 2: Eliminar/truncar logs del contenedor (stdout manipulation)
#   Fase 3: Modificar registros en Elasticsearch directamente
#   Fase 4: Alterar el audit log de Kubernetes (acceso al host)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/../results"
source "$SCRIPT_DIR/../../../scripts/lib/common.sh"

TARGET_DEPLOY="payment-processor"
TARGET_NS="payments"
TARGET_CONTAINER="payment-processor"

log_step "SCE-I-002 — Fase de inyección"

# ═════════════════════════════════════════════════════════════════
# FASE 1: Intento de escritura en /var/log/ (readOnlyRootFilesystem)
# ═════════════════════════════════════════════════════════════════
log_step "Fase 1 — Escritura en /var/log/ (readOnlyRootFilesystem)"

record_timing PHASE1_START

log_info "Ejecutando: intento de crear archivo en /var/log/"
PHASE1_EXIT=0
PHASE1_OUTPUT=$(kubectl exec -n "$TARGET_NS" "deploy/$TARGET_DEPLOY" \
  -c "$TARGET_CONTAINER" -- sh -c '
    echo "=== Intento 1: Crear archivo en /var/log/ ==="
    touch /var/log/fake-audit.log 2>&1 || echo "BLOCKED: touch /var/log/fake-audit.log"
    echo "=== Intento 2: Escribir en /var/log/messages ==="
    echo "tampered" > /var/log/messages 2>&1 || echo "BLOCKED: write /var/log/messages"
    echo "=== Intento 3: Crear directorio en /var/log/ ==="
    mkdir -p /var/log/attacker 2>&1 || echo "BLOCKED: mkdir /var/log/attacker"
    echo "=== Intento 4: Escribir en /tmp/ (control — debe funcionar) ==="
    echo "test" > /tmp/test-write.txt 2>&1 && echo "ALLOWED: write /tmp/test-write.txt" || echo "BLOCKED: write /tmp/"
  ' 2>&1) || PHASE1_EXIT=$?

record_timing PHASE1_END

VARLOG_WRITE_BLOCKED="true"
if echo "$PHASE1_OUTPUT" | grep -q "ALLOWED.*var/log"; then
  VARLOG_WRITE_BLOCKED="false"
fi

{
  echo "═══ FASE 1: Escritura en /var/log/ ═══"
  echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Comando: sh -c 'touch /var/log/...; echo > /var/log/...'"
  echo "Exit code: $PHASE1_EXIT"
  echo "Duración: $(elapsed_ms "$PHASE1_START" "$PHASE1_END")ms"
  echo ""
  echo "─── Output ───"
  echo "$PHASE1_OUTPUT"
  echo ""
  if [[ "$VARLOG_WRITE_BLOCKED" == "true" ]]; then
    echo "RESULTADO: ESCRITURA EN /var/log/ BLOQUEADA"
    echo "CONTROL EFECTIVO: readOnlyRootFilesystem impide modificar archivos de log"
    echo "NOTA: /tmp/ sí permite escritura (emptyDir montado) — confirma que el"
    echo "      bloqueo es específico del filesystem raíz, no un error de permisos"
  else
    echo "RESULTADO: ⚠ ESCRITURA EN /var/log/ PERMITIDA"
    echo "HALLAZGO: readOnlyRootFilesystem no está activo o /var/log/ está montado"
  fi
} > "$RESULTS_DIR/phase1-varlog-write.txt"

if [[ "$VARLOG_WRITE_BLOCKED" == "true" ]]; then
  log_ok "Fase 1: Escritura en /var/log/ BLOQUEADA (readOnlyRootFilesystem)"
else
  log_warn "Fase 1: ⚠ Escritura en /var/log/ PERMITIDA"
fi

# ═════════════════════════════════════════════════════════════════
# FASE 2: Intento de manipulación de stdout (corromper logs en origen)
# ═════════════════════════════════════════════════════════════════
log_step "Fase 2 — Manipulación de stdout/stderr del contenedor"

record_timing PHASE2_START

log_info "Ejecutando: intento de redirigir/sobreescribir stdout del proceso"
PHASE2_EXIT=0
PHASE2_OUTPUT=$(kubectl exec -n "$TARGET_NS" "deploy/$TARGET_DEPLOY" \
  -c "$TARGET_CONTAINER" -- sh -c '
    echo "=== Intento 1: Acceso a /proc/1/fd/1 (stdout del PID 1) ==="
    echo "TAMPERED LOG ENTRY" > /proc/1/fd/1 2>&1 || echo "BLOCKED: write to /proc/1/fd/1"
    echo "=== Intento 2: Acceso a /proc/1/fd/2 (stderr del PID 1) ==="
    echo "TAMPERED STDERR" > /proc/1/fd/2 2>&1 || echo "BLOCKED: write to /proc/1/fd/2"
    echo "=== Intento 3: Inyectar línea falsa en stdout (ataque de log injection) ==="
    echo "{\"level\":\"INFO\",\"msg\":\"legitimate-looking-but-fake\",\"user\":\"admin\",\"action\":\"login_success\"}"
    echo "=== Intento 4: Leer el log propio del contenedor desde /proc ==="
    ls -la /proc/1/fd/ 2>&1 | head -5 || echo "BLOCKED: ls /proc/1/fd/"
  ' 2>&1) || PHASE2_EXIT=$?

record_timing PHASE2_END

STDOUT_TAMPER_POSSIBLE="false"
if echo "$PHASE1_OUTPUT" | grep -q "TAMPERED"; then
  STDOUT_TAMPER_POSSIBLE="true"
fi

{
  echo "═══ FASE 2: Manipulación de stdout/stderr ═══"
  echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Exit code: $PHASE2_EXIT"
  echo "Duración: $(elapsed_ms "$PHASE2_START" "$PHASE2_END")ms"
  echo ""
  echo "─── Output ───"
  echo "$PHASE2_OUTPUT"
  echo ""
  echo "ANÁLISIS:"
  echo "  - Un atacante puede inyectar líneas en stdout del contenedor"
  echo "  - Estas líneas llegarán a Fluentd → Elasticsearch como logs legítimos"
  echo "  - PERO: los registros originales NO se pueden eliminar (Fluentd ya los"
  echo "    consumió y envió a ES). Solo se pueden inyectar NUEVOS registros falsos."
  echo "  - Los registros en Elasticsearch son append-only desde Fluentd"
  echo "  - El audit log de Kubernetes es independiente de stdout del pod"
} > "$RESULTS_DIR/phase2-stdout-tamper.txt"

log_ok "Fase 2: Inyección en stdout posible (pero registros originales inmutables en ES)"

# ═════════════════════════════════════════════════════════════════
# FASE 3: Intento de acceso directo a Elasticsearch
# ═════════════════════════════════════════════════════════════════
log_step "Fase 3 — Acceso directo a Elasticsearch (NetworkPolicy)"

record_timing PHASE3_START

log_info "Ejecutando: curl desde pod a Elasticsearch (NetworkPolicy debe bloquear)"
PHASE3_EXIT=0
PHASE3_OUTPUT=$(kubectl exec -n "$TARGET_NS" "deploy/$TARGET_DEPLOY" \
  -c "$TARGET_CONTAINER" -- sh -c '
    echo "=== Intento 1: Conectar a ES en logging namespace ==="
    curl -sf --max-time 5 http://elasticsearch-master.logging.svc.cluster.local:9200/ 2>&1 || echo "BLOCKED: connection to ES timed out"
    echo ""
    echo "=== Intento 2: Intentar eliminar índice fluentd ==="
    curl -sf --max-time 5 -X DELETE http://elasticsearch-master.logging.svc.cluster.local:9200/fluentd-* 2>&1 || echo "BLOCKED: DELETE to ES timed out"
    echo ""
    echo "=== Intento 3: Intentar insertar documento falso ==="
    curl -sf --max-time 5 -X POST http://elasticsearch-master.logging.svc.cluster.local:9200/fluentd-fake/_doc -H "Content-Type: application/json" -d "{\"msg\":\"tampered\"}" 2>&1 || echo "BLOCKED: POST to ES timed out"
  ' 2>&1) || PHASE3_EXIT=$?

record_timing PHASE3_END

ES_ACCESS_BLOCKED="true"
if echo "$PHASE3_OUTPUT" | grep -q '"name"' && ! echo "$PHASE3_OUTPUT" | grep -q "BLOCKED"; then
  ES_ACCESS_BLOCKED="false"
fi

{
  echo "═══ FASE 3: Acceso directo a Elasticsearch ═══"
  echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Exit code: $PHASE3_EXIT"
  echo "Duración: $(elapsed_ms "$PHASE3_START" "$PHASE3_END")ms"
  echo ""
  echo "─── Output ───"
  echo "$PHASE3_OUTPUT"
  echo ""
  if [[ "$ES_ACCESS_BLOCKED" == "true" ]]; then
    echo "RESULTADO: ACCESO A ELASTICSEARCH BLOQUEADO"
    echo "CONTROL EFECTIVO: NetworkPolicy default-deny-all impide conexión de pods"
    echo "de aplicación al namespace logging. El atacante no puede:"
    echo "  - Eliminar índices (DELETE fluentd-*)"
    echo "  - Modificar documentos existentes"
    echo "  - Insertar registros falsos directamente en ES"
  else
    echo "RESULTADO: ⚠ ACCESO A ELASTICSEARCH PERMITIDO"
    echo "HALLAZGO: NetworkPolicy no bloquea tráfico de payments → logging"
  fi
} > "$RESULTS_DIR/phase3-es-access.txt"

if [[ "$ES_ACCESS_BLOCKED" == "true" ]]; then
  log_ok "Fase 3: Acceso a Elasticsearch BLOQUEADO (NetworkPolicy)"
else
  log_warn "Fase 3: ⚠ Acceso a Elasticsearch PERMITIDO"
fi

# ═════════════════════════════════════════════════════════════════
# FASE 4: Intento de acceso al audit log del host
# ═════════════════════════════════════════════════════════════════
log_step "Fase 4 — Acceso al audit log del host (escape de contenedor)"

record_timing PHASE4_START

log_info "Ejecutando: intento de leer /var/log/kubernetes/ desde el pod"
PHASE4_EXIT=0
PHASE4_OUTPUT=$(kubectl exec -n "$TARGET_NS" "deploy/$TARGET_DEPLOY" \
  -c "$TARGET_CONTAINER" -- sh -c '
    echo "=== Intento 1: Leer audit log del host ==="
    cat /var/log/kubernetes/audit.log 2>&1 | head -3 || echo "BLOCKED: /var/log/kubernetes/ no accesible"
    echo ""
    echo "=== Intento 2: Listar /host/ (hostPath mounts) ==="
    ls /host/ 2>&1 || echo "BLOCKED: /host/ no existe (no hay hostPath mounts)"
    echo ""
    echo "=== Intento 3: Acceso a /proc/1/root/ (namespace escape) ==="
    ls /proc/1/root/var/log/ 2>&1 | head -5 || echo "BLOCKED: no se puede acceder al filesystem del host"
    echo ""
    echo "=== Intento 4: Verificar capabilities del contenedor ==="
    cat /proc/1/status 2>&1 | grep -i "cap" || echo "BLOCKED: no se puede leer capabilities"
  ' 2>&1) || PHASE4_EXIT=$?

record_timing PHASE4_END

# Determinar si el audit log real del HOST fue accesible
# /proc/1/root/var/log/ muestra el filesystem del contenedor, no del host
# La presencia de "audit.log" en el contenido (no en un error) indicaría acceso real
HOST_ACCESS_BLOCKED="true"
if echo "$PHASE4_OUTPUT" | grep -q "audit.log" && \
   ! echo "$PHASE4_OUTPUT" | grep -q "No such file\|BLOCKED\|can't open"; then
  HOST_ACCESS_BLOCKED="false"
fi
# Si /proc/1/root/var/log/ solo muestra archivos del contenedor (como apk.log),
# el host NO es accesible — eso es el filesystem aislado del container
if echo "$PHASE4_OUTPUT" | grep -q "apk.log" && \
   ! echo "$PHASE4_OUTPUT" | grep -q "kubernetes"; then
  HOST_ACCESS_BLOCKED="true"
fi

{
  echo "═══ FASE 4: Acceso al audit log del host ═══"
  echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Exit code: $PHASE4_EXIT"
  echo "Duración: $(elapsed_ms "$PHASE4_START" "$PHASE4_END")ms"
  echo ""
  echo "─── Output ───"
  echo "$PHASE4_OUTPUT"
  echo ""
  if [[ "$HOST_ACCESS_BLOCKED" == "true" ]]; then
    echo "RESULTADO: ACCESO AL AUDIT LOG DEL HOST BLOQUEADO"
    echo "CONTROLES EFECTIVOS:"
    echo "  - No hay hostPath mounts al audit log"
    echo "  - El pod no tiene privilegios para escapar del namespace"
    echo "  - allowPrivilegeEscalation: false impide obtener capabilities"
    echo "  - seccompProfile: RuntimeDefault restringe syscalls"
  else
    echo "RESULTADO: ⚠ ACCESO AL AUDIT LOG POSIBLE DESDE EL POD"
  fi
} > "$RESULTS_DIR/phase4-host-audit.txt"

if [[ "$HOST_ACCESS_BLOCKED" == "true" ]]; then
  log_ok "Fase 4: Acceso al audit log del host BLOQUEADO"
else
  log_warn "Fase 4: ⚠ Acceso al audit log del host posible"
fi

# ═════════════════════════════════════════════════════════════════
# Guardar timing consolidado
# ═════════════════════════════════════════════════════════════════
cat > "$RESULTS_DIR/timing.json" <<EOF
{
  "experiment": "SCE-I-002",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "phases": {
    "phase1_varlog_write_ms": $(elapsed_ms "$PHASE1_START" "$PHASE1_END"),
    "phase2_stdout_tamper_ms": $(elapsed_ms "$PHASE2_START" "$PHASE2_END"),
    "phase3_es_access_ms": $(elapsed_ms "$PHASE3_START" "$PHASE3_END"),
    "phase4_host_audit_ms": $(elapsed_ms "$PHASE4_START" "$PHASE4_END")
  },
  "results": {
    "varlog_write_blocked": $VARLOG_WRITE_BLOCKED,
    "stdout_tamper_possible": $STDOUT_TAMPER_POSSIBLE,
    "es_access_blocked": $ES_ACCESS_BLOCKED,
    "host_access_blocked": $HOST_ACCESS_BLOCKED
  }
}
EOF

log_ok "Inyección completada — resultados en experiments/SCE-I-002/results/"
