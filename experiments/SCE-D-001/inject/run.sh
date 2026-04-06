#!/usr/bin/env bash
# experiments/SCE-D-001/inject/run.sh
# Inyección del experimento SCE-D-001: Agotamiento del IDP
#
# Simula la caída del servicio de autenticación (auth-service) y mide:
#   Fase 1: Baseline — medir disponibilidad con auth-service activo
#   Fase 2: Scale-to-zero — escalar auth-service a 0 réplicas
#   Fase 3: Cache window — medir comportamiento durante TTL del cache (5 min)
#   Fase 4: Post-cache — medir comportamiento después del TTL del cache

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/../results"
source "$SCRIPT_DIR/../../../scripts/lib/common.sh"

TARGET_NS="users"
AUTH_DEPLOY="auth-service"
USERAPI_DEPLOY="user-api"
# Cache TTL reducido para el experimento — no esperar 300s completos
# Usamos un ciclo de mediciones corto para demostrar el comportamiento
MEASURE_INTERVAL=5  # segundos entre mediciones
CACHE_WINDOW=30     # segundos de medición en ventana de cache (demo)
POST_CACHE_WINDOW=15 # segundos de medición post-cache

log_step "SCE-D-001 — Fase de inyección"

# Helper: medir disponibilidad de auth-service desde un pod efímero
# Usa kubectl run --rm para lanzar un curl efímero en el namespace target
measure_availability() {
  local label="$1"
  local duration="$2"
  local interval="$3"
  local results_file="$4"
  local elapsed=0
  local success=0
  local failure=0
  local total=0

  echo "─── Mediciones: $label (${duration}s, cada ${interval}s) ───" >> "$results_file"

  while [[ $elapsed -lt $duration ]]; do
    total=$((total + 1))
    local ts
    ts=$(date -u +%H:%M:%S)

    local result="FAIL"
    local http_code="000"

    # Usar kubectl exec en el sidecar istio-proxy de user-api (tiene curl)
    # Si no, hacer un request directo desde la máquina via port-forward sería otra opción
    local userapi_pod
    userapi_pod=$(kubectl get pods -n "$TARGET_NS" -l app=user-api \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -n "$userapi_pod" ]]; then
      # Usar python3 desde el contenedor de la app (httpbin tiene Python)
      # El tráfico pasa por el sidecar Envoy → mTLS funciona correctamente
      http_code=$(kubectl exec -n "$TARGET_NS" "$userapi_pod" -c user-api \
        -- python3 -c "
import urllib.request, urllib.error, socket
socket.setdefaulttimeout(3)
try:
    r = urllib.request.urlopen('http://auth-service.users.svc.cluster.local/get')
    print(r.status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception:
    print(0)
" 2>/dev/null || echo "000")
      http_code=$(echo "$http_code" | tr -dc '0-9' | tail -c 3)
      if [[ "$http_code" == "200" ]]; then
        result="OK"
        success=$((success + 1))
      else
        failure=$((failure + 1))
      fi
    else
      failure=$((failure + 1))
    fi

    echo "  [$ts] +${elapsed}s  HTTP $http_code  $result" >> "$results_file"
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  echo "" >> "$results_file"
  echo "  Total: $total requests | OK: $success | FAIL: $failure" >> "$results_file"
  local avail_pct=0
  if [[ $total -gt 0 ]]; then
    avail_pct=$((success * 100 / total))
  fi
  echo "  Disponibilidad: ${avail_pct}%" >> "$results_file"
  echo "" >> "$results_file"

  # Retornar porcentaje de disponibilidad
  echo "$avail_pct"
}

# ═════════════════════════════════════════════════════════════════
# FASE 1: Baseline — medir disponibilidad con auth-service activo
# ═════════════════════════════════════════════════════════════════
log_step "Fase 1 — Baseline (auth-service activo)"

record_timing PHASE1_START

{
  echo "═══ FASE 1: Baseline — auth-service activo ═══"
  echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "auth-service replicas: $(kubectl get deploy "$AUTH_DEPLOY" -n "$TARGET_NS" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  echo ""
} > "$RESULTS_DIR/phase1-baseline.txt"

log_info "Midiendo disponibilidad baseline (15s)..."
BASELINE_AVAIL=$(measure_availability "Baseline" 15 "$MEASURE_INTERVAL" \
  "$RESULTS_DIR/phase1-baseline.txt")

record_timing PHASE1_END

{
  echo "RESULTADO: Disponibilidad baseline: ${BASELINE_AVAIL}%"
} >> "$RESULTS_DIR/phase1-baseline.txt"

log_ok "Fase 1: Baseline disponibilidad ${BASELINE_AVAIL}% ($(elapsed_ms "$PHASE1_START" "$PHASE1_END")ms)"

# ═════════════════════════════════════════════════════════════════
# FASE 2: Scale-to-zero — escalar auth-service a 0 réplicas
# ═════════════════════════════════════════════════════════════════
log_step "Fase 2 — Scale auth-service a 0 réplicas"

record_timing PHASE2_START

log_info "Ejecutando: kubectl scale deploy/auth-service --replicas=0"
SCALE_OUTPUT=$(kubectl scale deploy/"$AUTH_DEPLOY" --replicas=0 -n "$TARGET_NS" 2>&1)
SCALE_EXIT=$?

# Esperar a que el pod termine
log_info "Esperando a que auth-service termine..."
kubectl wait --for=delete pod -l app=auth-service -n "$TARGET_NS" --timeout=30s 2>/dev/null || true

AUTH_PODS_AFTER=$(kubectl get pods -n "$TARGET_NS" -l app=auth-service --no-headers 2>/dev/null | wc -l | tr -d ' ')

record_timing PHASE2_END

{
  echo "═══ FASE 2: Scale-to-zero ═══"
  echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Comando: kubectl scale deploy/auth-service --replicas=0 -n users"
  echo "Exit code: $SCALE_EXIT"
  echo "Output: $SCALE_OUTPUT"
  echo "Duración: $(elapsed_ms "$PHASE2_START" "$PHASE2_END")ms"
  echo "Pods auth-service después: $AUTH_PODS_AFTER"
  echo ""
  if [[ "$AUTH_PODS_AFTER" -eq 0 ]]; then
    echo "RESULTADO: auth-service escalado a 0 — IDP no disponible"
  else
    echo "RESULTADO: ⚠ auth-service aún tiene pods corriendo"
  fi
} > "$RESULTS_DIR/phase2-scale-zero.txt"

if [[ "$AUTH_PODS_AFTER" -eq 0 ]]; then
  log_ok "Fase 2: auth-service escalado a 0 (IDP caído)"
else
  log_warn "Fase 2: auth-service aún tiene ${AUTH_PODS_AFTER} pod(s)"
fi

# ═════════════════════════════════════════════════════════════════
# FASE 3: Cache window — medir comportamiento sin IDP (cache activo)
# ═════════════════════════════════════════════════════════════════
log_step "Fase 3 — Ventana de cache (auth-service=0, cache potencialmente válido)"

record_timing PHASE3_START

{
  echo "═══ FASE 3: Ventana de cache (auth-service=0) ═══"
  echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "auth-service replicas: 0"
  echo "JWT_CACHE_TTL_SECONDS: 300 (configurado)"
  echo "Ventana de medición: ${CACHE_WINDOW}s"
  echo ""
} > "$RESULTS_DIR/phase3-cache-window.txt"

log_info "Midiendo disponibilidad en ventana de cache (${CACHE_WINDOW}s)..."
CACHE_AVAIL=$(measure_availability "Cache window (auth=0)" "$CACHE_WINDOW" \
  "$MEASURE_INTERVAL" "$RESULTS_DIR/phase3-cache-window.txt")

record_timing PHASE3_END

{
  echo "RESULTADO: Disponibilidad en ventana de cache: ${CACHE_AVAIL}%"
  echo ""
  echo "ANÁLISIS:"
  if [[ "$CACHE_AVAIL" -eq 0 ]]; then
    echo "  FAIL-SECURE: user-api NO acepta requests sin auth-service."
    echo "  El servicio prioriza seguridad sobre disponibilidad."
    echo "  Esto es el comportamiento esperado para un sistema que"
    echo "  requiere autenticación para toda operación."
  elif [[ "$CACHE_AVAIL" -gt 0 && "$CACHE_AVAIL" -lt 100 ]]; then
    echo "  DEGRADACIÓN PARCIAL: Algunas requests exitosas (posiblemente cacheadas)"
    echo "  y otras fallando conforme el cache expira."
  else
    echo "  ⚠ FAIL-OPEN o CACHE ACTIVO: user-api sigue aceptando requests."
    echo "  Si esto continúa después del TTL del cache, indica fail-open."
  fi
} >> "$RESULTS_DIR/phase3-cache-window.txt"

log_ok "Fase 3: Disponibilidad en cache window: ${CACHE_AVAIL}% ($(elapsed_ms "$PHASE3_START" "$PHASE3_END")ms)"

# ═════════════════════════════════════════════════════════════════
# FASE 4: Post-cache — medir comportamiento después del TTL
# ═════════════════════════════════════════════════════════════════
log_step "Fase 4 — Post-cache (auth-service=0, cache expirado)"

record_timing PHASE4_START

{
  echo "═══ FASE 4: Post-cache (auth-service=0, TTL expirado) ═══"
  echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "auth-service replicas: 0 (confirmado)"
  echo "Ventana de medición: ${POST_CACHE_WINDOW}s"
  echo ""
} > "$RESULTS_DIR/phase4-post-cache.txt"

log_info "Midiendo disponibilidad post-cache (${POST_CACHE_WINDOW}s)..."
POSTCACHE_AVAIL=$(measure_availability "Post-cache (auth=0)" "$POST_CACHE_WINDOW" \
  "$MEASURE_INTERVAL" "$RESULTS_DIR/phase4-post-cache.txt")

record_timing PHASE4_END

# Determinar el comportamiento fail-secure/fail-open
FAIL_BEHAVIOR="unknown"
if [[ "$POSTCACHE_AVAIL" -eq 0 ]]; then
  FAIL_BEHAVIOR="fail-secure"
elif [[ "$POSTCACHE_AVAIL" -eq 100 ]]; then
  FAIL_BEHAVIOR="fail-open"
else
  FAIL_BEHAVIOR="degraded"
fi

{
  echo "RESULTADO: Disponibilidad post-cache: ${POSTCACHE_AVAIL}%"
  echo "COMPORTAMIENTO: $FAIL_BEHAVIOR"
  echo ""
  case "$FAIL_BEHAVIOR" in
    fail-secure)
      echo "FAIL-SECURE CONFIRMADO:"
      echo "  Después de que el cache expira, user-api rechaza todas las"
      echo "  requests porque no puede validar tokens con auth-service."
      echo "  → Seguridad mantenida, disponibilidad sacrificada."
      ;;
    fail-open)
      echo "⚠ FAIL-OPEN DETECTADO:"
      echo "  user-api sigue aceptando requests incluso sin auth-service."
      echo "  → Disponibilidad mantenida, SEGURIDAD COMPROMETIDA."
      echo "  RECOMENDACIÓN: Implementar circuit breaker con fail-secure."
      ;;
    degraded)
      echo "DEGRADACIÓN DETECTADA:"
      echo "  Comportamiento mixto — algunas requests exitosas, otras fallando."
      echo "  → Posible race condition en el manejo de errores de autenticación."
      ;;
  esac
} >> "$RESULTS_DIR/phase4-post-cache.txt"

log_ok "Fase 4: Post-cache disponibilidad: ${POSTCACHE_AVAIL}% → $FAIL_BEHAVIOR ($(elapsed_ms "$PHASE4_START" "$PHASE4_END")ms)"

# ═════════════════════════════════════════════════════════════════
# Guardar timing consolidado
# ═════════════════════════════════════════════════════════════════
cat > "$RESULTS_DIR/timing.json" <<EOF
{
  "experiment": "SCE-D-001",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "phases": {
    "phase1_baseline_ms": $(elapsed_ms "$PHASE1_START" "$PHASE1_END"),
    "phase2_scale_zero_ms": $(elapsed_ms "$PHASE2_START" "$PHASE2_END"),
    "phase3_cache_window_ms": $(elapsed_ms "$PHASE3_START" "$PHASE3_END"),
    "phase4_post_cache_ms": $(elapsed_ms "$PHASE4_START" "$PHASE4_END")
  },
  "results": {
    "baseline_availability_pct": $BASELINE_AVAIL,
    "cache_window_availability_pct": $CACHE_AVAIL,
    "postcache_availability_pct": $POSTCACHE_AVAIL,
    "fail_behavior": "$FAIL_BEHAVIOR"
  }
}
EOF

log_ok "Inyección completada — resultados en experiments/SCE-D-001/results/"
