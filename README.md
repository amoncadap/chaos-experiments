# SCE Lab — Experimentos de Ingeniería del Caos

Experimentos del marco metodológico desarrollado en:

> **Construcción de Experimentos de Ingeniería del Caos para la Protección de la Información**
> Alejandro Moncada Pastrán — UBA CESI 2025-1

> **Prerequisito**: el cluster debe estar inicializado con el repo **sce-lab-infra**.

---

## Experimentos disponibles

| ID | Nombre | Propiedad CIA | Estado |
|---|---|---|---|
| SCE-C-001 | Exfiltración de credenciales vía ServiceAccount | Confidencialidad | Implementado |
| SCE-C-002 | Escalación de privilegios RBAC | Confidencialidad | Scaffolded |
| SCE-C-003 | Exposición de secretos en logs | Confidencialidad | Scaffolded |
| SCE-I-001 | Modificación de datos en tránsito (mTLS) | Integridad | Scaffolded |
| SCE-I-002 | Corrupción de registros de auditoría | Integridad | Implementado |
| SCE-D-001 | Agotamiento del IDP — fail-secure | Disponibilidad | Implementado |
| SCE-D-002 | Resiliencia de backups ante ransomware | Disponibilidad | Scaffolded |

---

## Ejecutar un experimento

```bash
make experiment-sce-c-001   # exfiltración de credenciales
make experiment-sce-i-002   # corrupción de registros
make experiment-sce-d-001   # agotamiento del IDP
```

Cada experimento sigue la estructura:

```
SCE-X-XXX/
├── run-experiment.sh        # orquestador principal
├── preconditions/check.sh   # validación de precondiciones
├── inject/run.sh            # ejecución del ataque
├── observe/
│   ├── collect-evidence.sh  # recolección de evidencia
│   └── generate-report.sh   # generación del reporte
├── rollback/cleanup.sh      # limpieza post-experimento
└── results/                 # resultados (en .gitignore)
```

---

## Estructura del repositorio

```
sce-lab-experiments/
├── Makefile
└── experiments/
    ├── SCE-C-001/
    ├── SCE-C-002/
    ├── SCE-C-003/
    ├── SCE-I-001/
    ├── SCE-I-002/
    ├── SCE-D-001/
    └── SCE-D-002/
```
