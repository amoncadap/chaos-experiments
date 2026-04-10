# =============================================================================
# SCE Lab - Experimentos de Ingeniería del Caos
# Universidad de Buenos Aires - Especialización en Seguridad Informática
# =============================================================================
# Requiere cluster inicializado con sce-lab-infra

KUBECTL        := kubectl

.DEFAULT_GOAL := help

.PHONY: help experiment-sce-c-001 experiment-sce-i-002 experiment-sce-d-001

help: ## Muestra esta ayuda
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}'

experiment-sce-c-001: ## Ejecuta SCE-C-001: exfiltración de credenciales (Confidencialidad)
	@bash experiments/SCE-C-001/run-experiment.sh

experiment-sce-i-002: ## Ejecuta SCE-I-002: corrupción de registros de auditoría (Integridad)
	@bash experiments/SCE-I-002/run-experiment.sh

experiment-sce-d-001: ## Ejecuta SCE-D-001: agotamiento del IDP - fail-secure (Disponibilidad)
	@bash experiments/SCE-D-001/run-experiment.sh
