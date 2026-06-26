# docs — ms-gitops

Documentația proiectului, organizată pe două zone.

```
docs/
├── diagrame/        ← scheme vizuale (drawio + pdf)
└── migrare/         ← planul + ghidurile de migrare a microserviciilor
```

## 📐 diagrame/
| Fișier | Ce arată |
|---|---|
| [`architecture-final`](diagrame/architecture-final.pdf) | arhitectura GitOps (infra: operatori, namespace-uri, waves) |
| [`services-communication`](diagrame/services-communication.pdf) | cum comunică microserviciile (cine ce face) |
| `architecture.drawio` | schema veche (referință) |

## 🚀 migrare/  → [intră aici](migrare/README.md)
Migrarea layer-ului business în GitOps, **serviciu cu serviciu**, cu CI/CD bine definit.

| Fișier | Rol |
|---|---|
| [`README`](migrare/README.md) | index + ordine + reguli + Definition of Done |
| [`MIGRATION_PLAN`](migrare/MIGRATION_PLAN.md) | strategia generală |
| [`BACKLOG`](migrare/BACKLOG.md) | epics + stories (Jira-style) |
| [`SOLUTIONS`](migrare/SOLUTIONS.md) | cod/config concret (CI, Testcontainers, manifeste) |
| `00-prerechizite` … `03-client-ui` | ghidurile de execuție pas-cu-pas |

## Cum se folosește
1. Înțelegi sistemul → `diagrame/`
2. Status infra + ce mai e de finisat → [`../NEXT_STEPS.md`](../NEXT_STEPS.md)
3. Planifici migrarea business → `migrare/MIGRATION_PLAN` + `BACKLOG`
4. Execuți → `migrare/00 → 01 → 02 → 03` (sari în `SOLUTIONS` pt cod exact)

> Intrarea principală în repo: [`../README.md`](../README.md).
