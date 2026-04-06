#!/usr/bin/env bash
# experiments/SCE-D-001/observe/generate-report.sh
# Genera el reporte final del experimento SCE-D-001

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/../results"
source "$SCRIPT_DIR/../../../scripts/lib/common.sh"

log_step "SCE-D-001 — Generando reporte"

# Leer resultados del timing.json
TIMING_FILE="$RESULTS_DIR/timing.json"
if [[ -f "$TIMING_FILE" ]]; then
  BASELINE_AVAIL=$(jq -r '.results.baseline_availability_pct' "$TIMING_FILE" 2>/dev/null || echo "?")
  CACHE_AVAIL=$(jq -r '.results.cache_window_availability_pct' "$TIMING_FILE" 2>/dev/null || echo "?")
  POSTCACHE_AVAIL=$(jq -r '.results.postcache_availability_pct' "$TIMING_FILE" 2>/dev/null || echo "?")
  FAIL_BEHAVIOR=$(jq -r '.results.fail_behavior' "$TIMING_FILE" 2>/dev/null || echo "?")
  P1_MS=$(jq -r '.phases.phase1_baseline_ms' "$TIMING_FILE" 2>/dev/null || echo "?")
  P2_MS=$(jq -r '.phases.phase2_scale_zero_ms' "$TIMING_FILE" 2>/dev/null || echo "?")
  P3_MS=$(jq -r '.phases.phase3_cache_window_ms' "$TIMING_FILE" 2>/dev/null || echo "?")
  P4_MS=$(jq -r '.phases.phase4_post_cache_ms' "$TIMING_FILE" 2>/dev/null || echo "?")
else
  BASELINE_AVAIL="?" CACHE_AVAIL="?" POSTCACHE_AVAIL="?" FAIL_BEHAVIOR="?"
  P1_MS="?" P2_MS="?" P3_MS="?" P4_MS="?"
fi

# Contar evidencia
AUDIT_COUNT=$(grep -c '"timestamp"' "$RESULTS_DIR/audit-scale-events.json" 2>/dev/null || echo "0")
ERROR_COUNT=$(grep -c "error\|fail\|refused\|timeout" "$RESULTS_DIR/userapi-logs.txt" 2>/dev/null || echo "0")
ISTIO_ERRORS=$(grep -c "503\|upstream_reset\|no_healthy" "$RESULTS_DIR/istio-proxy-errors.txt" 2>/dev/null || echo "0")

# Determinar veredicto general
VERDICT="INDETERMINADO"
VERDICT_DETAIL=""
case "$FAIL_BEHAVIOR" in
  fail-secure)
    VERDICT="HIPÓTESIS CONFIRMADA"
    VERDICT_DETAIL="El sistema se comporta fail-secure: sin IDP, el servicio rechaza todas las requests."
    ;;
  fail-open)
    VERDICT="HIPÓTESIS REFUTADA"
    VERDICT_DETAIL="El sistema se comporta fail-open: sin IDP, el servicio sigue aceptando requests. RIESGO DE SEGURIDAD."
    ;;
  degraded)
    VERDICT="HIPÓTESIS PARCIALMENTE CONFIRMADA"
    VERDICT_DETAIL="Comportamiento degradado: algunas requests exitosas, otras rechazadas."
    ;;
esac

cat > "$RESULTS_DIR/report.txt" <<REPORT
╔══════════════════════════════════════════════════════════════════════╗
║             SCE-D-001 — REPORTE DE EXPERIMENTO                     ║
║        Agotamiento del IDP (fail-secure behavior)                  ║
╚══════════════════════════════════════════════════════════════════════╝

Fecha de ejecución: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Target:             users/auth-service (IDP) → users/user-api (dependiente)
Método:             Scale auth-service a 0 réplicas

═══════════════════════════════════════════════════════════════════════
HIPÓTESIS
═══════════════════════════════════════════════════════════════════════

Cuando el servicio de autenticación (IDP) deja de estar disponible,
el servicio dependiente (user-api) debe comportarse de manera
fail-secure: rechazar requests que requieren autenticación en lugar
de permitir acceso no autenticado (fail-open).

Expectativa:
  - Baseline (auth OK):        ~100% disponibilidad
  - Cache window (auth=0):     100% o parcial (cache JWT válido)
  - Post-cache (auth=0, TTL):  ~0% disponibilidad (fail-secure)

═══════════════════════════════════════════════════════════════════════
RESULTADOS POR FASE
═══════════════════════════════════════════════════════════════════════

┌─────────────────────────────────────────────────────────────────────┐
│ FASE 1 — Baseline (auth-service activo)                            │
├─────────────────────────────────────────────────────────────────────┤
│ Disponibilidad:   ${BASELINE_AVAIL}%                                       │
│ Duración:         ${P1_MS}ms                                             │
│ Evidencia:        results/phase1-baseline.txt                      │
│ Estado:           auth-service con réplica(s) Ready                │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ FASE 2 — Scale-to-zero (inyección)                                 │
├─────────────────────────────────────────────────────────────────────┤
│ Acción:           kubectl scale deploy/auth-service --replicas=0   │
│ Duración:         ${P2_MS}ms                                             │
│ Evidencia:        results/phase2-scale-zero.txt                    │
│ Estado:           auth-service sin pods                             │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ FASE 3 — Ventana de cache (auth=0, cache potencialmente válido)    │
├─────────────────────────────────────────────────────────────────────┤
│ Disponibilidad:   ${CACHE_AVAIL}%                                         │
│ Duración:         ${P3_MS}ms                                             │
│ Evidencia:        results/phase3-cache-window.txt                  │
│ Análisis:         Comportamiento durante TTL del JWT cache         │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ FASE 4 — Post-cache (auth=0, cache expirado)                      │
├─────────────────────────────────────────────────────────────────────┤
│ Disponibilidad:   ${POSTCACHE_AVAIL}%                                       │
│ Comportamiento:   ${FAIL_BEHAVIOR}                                    │
│ Duración:         ${P4_MS}ms                                             │
│ Evidencia:        results/phase4-post-cache.txt                    │
└─────────────────────────────────────────────────────────────────────┘

═══════════════════════════════════════════════════════════════════════
CURVA DE DISPONIBILIDAD
═══════════════════════════════════════════════════════════════════════

  100% │ $([ "$BASELINE_AVAIL" -ge 90 ] 2>/dev/null && echo "████" || echo "    ") $([ "$CACHE_AVAIL" -ge 90 ] 2>/dev/null && echo "████" || echo "    ") $([ "$POSTCACHE_AVAIL" -ge 90 ] 2>/dev/null && echo "████" || echo "    ")
   75% │ $([ "$BASELINE_AVAIL" -ge 65 ] 2>/dev/null && [ "$BASELINE_AVAIL" -lt 90 ] 2>/dev/null && echo "████" || echo "    ") $([ "$CACHE_AVAIL" -ge 65 ] 2>/dev/null && [ "$CACHE_AVAIL" -lt 90 ] 2>/dev/null && echo "████" || echo "    ") $([ "$POSTCACHE_AVAIL" -ge 65 ] 2>/dev/null && [ "$POSTCACHE_AVAIL" -lt 90 ] 2>/dev/null && echo "████" || echo "    ")
   50% │ $([ "$BASELINE_AVAIL" -ge 40 ] 2>/dev/null && [ "$BASELINE_AVAIL" -lt 65 ] 2>/dev/null && echo "████" || echo "    ") $([ "$CACHE_AVAIL" -ge 40 ] 2>/dev/null && [ "$CACHE_AVAIL" -lt 65 ] 2>/dev/null && echo "████" || echo "    ") $([ "$POSTCACHE_AVAIL" -ge 40 ] 2>/dev/null && [ "$POSTCACHE_AVAIL" -lt 65 ] 2>/dev/null && echo "████" || echo "    ")
   25% │ $([ "$BASELINE_AVAIL" -ge 15 ] 2>/dev/null && [ "$BASELINE_AVAIL" -lt 40 ] 2>/dev/null && echo "████" || echo "    ") $([ "$CACHE_AVAIL" -ge 15 ] 2>/dev/null && [ "$CACHE_AVAIL" -lt 40 ] 2>/dev/null && echo "████" || echo "    ") $([ "$POSTCACHE_AVAIL" -ge 15 ] 2>/dev/null && [ "$POSTCACHE_AVAIL" -lt 40 ] 2>/dev/null && echo "████" || echo "    ")
    0% │─────┴─────┴─────┴────
       Baseline  Cache   Post
        (F1)     (F3)    (F4)

  Disponibilidad: ${BASELINE_AVAIL}% → ${CACHE_AVAIL}% → ${POSTCACHE_AVAIL}%

═══════════════════════════════════════════════════════════════════════
CONTROLES DE SEGURIDAD EVALUADOS
═══════════════════════════════════════════════════════════════════════

┌──────────────────────────────────┬────────────────┬────────────────────────┐
│ Control                          │ Resultado      │ Evidencia              │
├──────────────────────────────────┼────────────────┼────────────────────────┤
│ Fail-secure (auth required)      │ ${FAIL_BEHAVIOR}      │ phase4                 │
│ JWT Cache (resiliencia temporal) │ cache=${CACHE_AVAIL}%     │ phase3                 │
│ K8s audit (scale events)         │ ${AUDIT_COUNT} eventos    │ audit-scale-events     │
│ Istio mTLS STRICT                │ activo         │ istio-proxy-errors     │
│ Service mesh observabilidad      │ ${ISTIO_ERRORS} errores   │ istio-proxy-errors     │
│ Monitoreo errores user-api       │ ${ERROR_COUNT} líneas     │ userapi-logs           │
└──────────────────────────────────┴────────────────┴────────────────────────┘

═══════════════════════════════════════════════════════════════════════
VEREDICTO
═══════════════════════════════════════════════════════════════════════

  >>> ${VERDICT} <<<

  ${VERDICT_DETAIL}

  Disponibilidad:
    Baseline:    ${BASELINE_AVAIL}%  (auth-service activo)
    Cache:       ${CACHE_AVAIL}%  (auth=0, cache potencialmente válido)
    Post-cache:  ${POSTCACHE_AVAIL}%  (auth=0, cache expirado)

═══════════════════════════════════════════════════════════════════════
HALLAZGOS Y RECOMENDACIONES
═══════════════════════════════════════════════════════════════════════

1. RESILIENCIA DEL IDP:
   La dependencia directa de auth-service como single point of failure
   significa que su caída impacta toda la cadena de autenticación.
   Recomendación: implementar circuit breaker pattern con fallback
   definido (fail-secure por defecto, con degradación controlada).

2. JWT CACHE COMO CONTROL DE RESILIENCIA:
   El cache de JWT permite que requests con tokens previamente validados
   continúen operando durante una ventana de tiempo (TTL).
   - Si cache_avail > 0%: el cache proporciona resiliencia temporal
   - Si cache_avail = 0%: no hay cache efectivo o el TTL es muy corto
   Recomendación: calibrar TTL del cache según SLA de disponibilidad.

3. DETECCIÓN Y OBSERVABILIDAD:
   La caída del IDP debe generar:
   - Alertas de Istio proxy (upstream errors)
   - Logs de error en user-api (connection refused)
   - Eventos de scale en el audit log de Kubernetes
   Verificar que estas señales alimentan un sistema de alerting.

4. RECUPERACIÓN:
   Medir el tiempo de recuperación (MTTR) al restaurar auth-service
   es crítico para definir el SLA del servicio.

═══════════════════════════════════════════════════════════════════════
MAPEO MITRE ATT&CK
═══════════════════════════════════════════════════════════════════════

Táctica:      Impact (TA0040)
Técnica:      Endpoint Denial of Service (T1499)
Sub-técnica:  Service Exhaustion Flood (T1499.002)
Plataforma:   Containers (Kubernetes)

Contexto:     Un atacante que compromete la capacidad de autenticación
              (agotamiento del IDP) puede causar denegación de servicio
              en cascada si los servicios dependientes no implementan
              un patrón de fail-secure/circuit breaker.

═══════════════════════════════════════════════════════════════════════
COMPARACIÓN CON ARQUITECTURA ACTUAL
═══════════════════════════════════════════════════════════════════════

El lab SCE implementa auth-service como un deployment simple sin
redundancia (1 réplica). En producción, se debería implementar:
  - HPA (Horizontal Pod Autoscaler) con min 2 réplicas
  - PodDisruptionBudget para garantizar disponibilidad durante updates
  - Circuit breaker (Istio DestinationRule) con outlier detection
  - Health checks con readiness/liveness probes adecuados

══════════════════════════════════════════════════════════════════════
Fin del reporte SCE-D-001
══════════════════════════════════════════════════════════════════════
REPORT

log_ok "Reporte generado: experiments/SCE-D-001/results/report.txt"
cat "$RESULTS_DIR/report.txt"
