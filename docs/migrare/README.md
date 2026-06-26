# Ghiduri de migrare — microservicii în GitOps

Directive **pas cu pas**, serviciu cu serviciu, pentru a aduce layer-ul business în clusterul GitOps cu CI/CD bine definit.

> Context: [`../services-communication.pdf`](../diagrame/services-communication.pdf) · [`../MIGRATION_PLAN.md`](MIGRATION_PLAN.md) · [`BACKLOG.md`](BACKLOG.md) · [`SOLUTIONS.md`](SOLUTIONS.md)

## Ordinea (obligatorie)
| # | Ghid | De ce în ordinea asta |
|---|---|---|
| 0 | [Prerechizite](00-prerechizite.md) | topic `product-topic` + realm `rsk` — TOATE depind de ele |
| 1 | [data-service](01-data-service.md) | e env-driven → cel mai ușor, validează lanțul |
| 2 | [importer-service](02-importer-service.md) | cere fix config (hardcodat) înainte |
| 3 | [client / UI](03-client-ui.md) | cere runtime-config; depinde de API-uri sus |

## Reguli comune (valabile la fiecare serviciu)
1. **Nu treci la următorul** până cel curent nu e Synced+Healthy în ArgoCD.
2. **Config prin env/ConfigMap**, niciodată hardcodat. Zero secrete în cod.
3. **Logging prin Filebeat**: logback → JSON pe stdout (NU appender Logstash TCP).
4. **Imagini**: `ion21/<svc>:<sha>` din CI; gitops bump-uit automat (cd-bump).
5. **Infra = operatori** (Strimzi/MOCO/Keycloak/ECK). NU folosi umbrella-ul `ubuntu-microservicii-helm` întreg.

## Definition of Done (orice serviciu)
- [ ] Config env-driven, zero hardcodări/secrete în cod
- [ ] Logback → JSON stdout (Filebeat), fără Logstash TCP
- [ ] Rulează local (docker-compose) + integration test (Testcontainers)
- [ ] CI: build-test verde → `ion21/<svc>:<sha>` în registry
- [ ] Manifest GitOps în `business/`, tag bump-uit de CI
- [ ] ArgoCD Synced + Healthy; smoke prin Kong + JWT (realm `rsk`)
