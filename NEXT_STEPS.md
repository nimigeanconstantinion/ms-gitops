# NEXT STEPS — constantin-gitops

> Stare la **2026-06-25**. Domeniu: `icode.mywire.org` (Dynu DDNS). Cluster: K3s.
> Diagramă: [`docs/architecture-final.pdf`](docs/architecture-final.pdf) — **linie continuă** = sincronizat, **linie punctată** = orphan / de făcut.

---

## 1. Ce construim (viziunea)

Platformă **GitOps completă** într-un singur repo: ArgoCD App-of-Apps, totul declarativ, `git push` = singura cale de a schimba clusterul. Pe straturi:

| Strat | Componente | ns | Status |
|---|---|---|---|
| Edge & TLS | nginx-ingress, cert-manager + Let's Encrypt | ingress-nginx, cert-manager | ✅ |
| Observability | kube-prometheus-stack (Grafana embedded) | monitoring | ✅ |
| Logging | ECK: Elasticsearch + Kibana + Filebeat | logging | ✅ |
| Messaging | Strimzi + Kafka (KRaft) + topics | messaging | ✅ |
| Data | CNPG + MOCO + MongoDB | data | 🟡 parțial |
| Auth | Keycloak Operator + Crossplane | auth, crossplane-system | 🟡 parțial |
| Business | Istio + Tempo + Kong + microservicii | business | ⬜ viitor |

---

## 2. Etapele de parcurs (status)

| Etapă | Ce livrează | Wave | Status |
|---|---|---|---|
| **Bootstrap** | sealed-secrets + nginx + cert-manager + reflector | 0–1 | ✅ |
| **P0 — Observability** | Prometheus + Alertmanager + Grafana + exporters | 1 | ✅ |
| **P1 — Logging** | Elasticsearch + Kibana + Filebeat (4 apps) | 0/2/3 | ✅ |
| **P2 — Messaging** | Kafka KRaft + 3 topics + Kafka UI | 0/2/3 | ✅ |
| **P3 — Data & Auth** | CNPG/MOCO/Mongo + Keycloak + Crossplane | 0–4 | 🟡 parțial |
| **P4 — Ingress public** | TLS pentru toate UI-urile (+ BasicAuth) | 4 | 🟡 parțial |
| **P5 — Cleanup & sec** | Hardening + fix host-uri | — | ⬜ |
| **P6 — Business layer** | Istio + Tempo + Kong + microservicii | viitor | ⬜ |

---

## 3. Ce ai livrat (✅)

- **Bootstrap + Edge:** sealed-secrets, nginx-ingress, cert-manager + `letsencrypt-prod`, reflector.
- **P0 Observability:** kube-prometheus-stack cu Grafana embedded — **live** la `grafana.icode.mywire.org`, datasource Prometheus auto + dashboards.
- **P1 Logging:** ECK operator + Elasticsearch + Kibana + Filebeat (DaemonSet), fiecare **Application separată** (eck W0, elasticsearch W2, kibana W3, filebeat W3). Kibana la `kibana.icode.mywire.org`.
- **P2 Messaging:** Strimzi + Kafka KRaft + 3 topics (`orders`, `events`, `notifications`) + Kafka UI.
- **P3 Auth (parțial):** Keycloak Operator în ns `auth` + Keycloak CR + Ingress `auth.icode.mywire.org` + `KeycloakRealmImport demo`. DB `postgres-keycloak` (CNPG) wired separat, secret oglindit via Reflector.

---

## 4. Ce mai e de făcut (🟡 — în ordinea recomandată)

### a) Wire `infra/databases/` — momentan **orphan**
`infra/databases/` conține `mysql.yaml`, `mongodb.yaml`, `postgres-cluster.yaml`, dar **niciun Application din `argo-apps/` nu le sincronizează** → operatorii MOCO și MongoDB rulează fără CR-uri. Adaugă o Application:

```yaml
# argo-apps/infra-databases.yaml — wave 2 (după operatori W0/W1)
# source.path: infra/databases  +  directory.recurse: true (ca să prindă secrets/)
```
**Verify:** `kubectl -n data get cluster,mysqlcluster,mongodbcommunity` → `mysql`, `mongodb`, `postgres` apar Ready.

### b) Populează `apps/` — Crossplane realms declarativi
`apps/` are doar `README.md`, dar `infra-keycloak-realms.yaml` (W4) sincronizează `apps/`. Crossplane (core + provider + config) e instalat, dar **nu produce niciun Realm**. Adaugă `Realm` + `Client` + `Role` CR-uri (provider-keycloak) în `apps/<realm>/`.
**Verify:** `kubectl get realm,client,role -A` → resursele tale apar `SYNCED=True`.

### c) Fix host Kafka UI (copy-paste din alt repo)
`infra/kafka-ui/values.yaml` → `host: kafka-ui.aws.mycodepractice.com`. Schimbă în `kafka-ui.icode.mywire.org` (domeniul tău).
**Verify:** `https://kafka-ui.icode.mywire.org` deschide UI-ul.

### d) P4 — expune Prometheus + Alertmanager
Nu au Ingress. Adaugă Ingress cu TLS **+ BasicAuth** (sensitive):
```bash
htpasswd -c -b auth admin "<parola>"
kubectl create secret generic basic-auth-prom --from-file=auth --dry-run=client -o yaml > raw.yaml
kubeseal --format yaml < raw.yaml > infra/.../basic-auth-prom-sealed.yaml
```
Adnotări nginx: `auth-type: basic`, `auth-secret: basic-auth-prom`.

---

## 5. Cleanup & viitor

- **P5:** audit `kind: Secret` plain → SealedSecret; `.gitignore` strict pe `*-raw.yaml`; verifică comentarii leftover din starter în `bootstrap/root.yaml`.
- **P6 (opțional, după platformă):** Istio (mTLS STRICT) + Tempo (tracing) + Kong (gateway intern) + microservicii cu `istio-injection=enabled`.

---

## 6. Următorul pas concret

**Wire `infra/databases/`** (punctul 4.a) — un commit (`feat: add infra-databases Application — wire mysql/mongo/postgres`), apoi verifică în UI ArgoCD că Application e Synced + Healthy.

> Reminder: o etapă = un commit + push → ArgoCD sync. **Niciodată** `kubectl apply` manual pe resurse gestionate de ArgoCD.
