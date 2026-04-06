#!/usr/bin/env bash
# experiments/SCE-I-002/run-experiment.sh
# Orquestador principal del experimento SCE-I-002
#
# Corrupción de registros de auditoría
# Capítulo 4 — Trabajo Final SCE

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../scripts/lib/common.sh"

RESULTS_DIR="$SCRIPT_DIR/results"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  SCE-I-002: Corrupción de registros de auditoría           ║${NC}"
echo -e "${BOLD}║                                                            ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

record_timing EXPERIMENT_START

# ─── Preparar directorio de resultados ─────────────────────────
mkdir -p "$RESULTS_DIR"
log_info "Resultados se guardarán en: experiments/SCE-I-002/results/"

# ─── Fase 0: Precondiciones ───────────────────────────────────
bash "$SCRIPT_DIR/preconditions/check.sh"
echo ""

# ─── Fases 1-4: Inyección ────────────────────────────────────
bash "$SCRIPT_DIR/inject/run.sh"
echo ""

# ─── Recolección de evidencia ─────────────────────────────────
log_info "Esperando 10s para que Fluentd procese los eventos..."
sleep 10

bash "$SCRIPT_DIR/observe/collect-evidence.sh"
echo ""

# ─── Generar reporte ──────────────────────────────────────────
bash "$SCRIPT_DIR/observe/generate-report.sh"
echo ""

# ─── Rollback ─────────────────────────────────────────────────
bash "$SCRIPT_DIR/rollback/cleanup.sh"

# ─── Resumen final ────────────────────────────────────────────
record_timing EXPERIMENT_END

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║  SCE-I-002 completado en $(elapsed_ms "$EXPERIMENT_START" "$EXPERIMENT_END")ms${NC}"
echo -e "${BOLD}${GREEN}║                                                            ║${NC}"
echo -e "${BOLD}${GREEN}║  Resultados: experiments/SCE-I-002/results/                ║${NC}"
echo -e "${BOLD}${GREEN}║  Reporte:    experiments/SCE-I-002/results/report.txt      ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
