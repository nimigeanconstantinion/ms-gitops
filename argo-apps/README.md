# `argo-apps/` — catalog Applications

Folder scanat de `bootstrap/root.yaml` cu `recurse: false`. Fiecare fișier `infra-*.yaml` devine un `Application` ArgoCD automat după push.

## Catalog (13 Applications)

| Wave | Application | Namespace | Sursă | Scop |
|---|---|---|---|---|
| 0 (implicit) | `sealed-secrets` | `kube-system` | Helm `bitnami-labs/sealed-secrets` 2.16.2 | Decriptează SealedSecret-uri din git → Secret-uri normale |
| 0 (implicit) | `nginx-ingress` | `ingress-nginx` | Helm `kubernetes/ingress-nginx` 4.11.3 | Controller Ingress; expune servicii HTTP/HTTPS |
| 0 (implicit) | `cert-manager` | `cert-manager` | Helm `jetstack/cert-manager` v1.16.2 | Operator + CRD ClusterIssuer/Certificate |
| 0 (implicit) | `eck-operator` | `elastic-system` | Helm `elastic/eck-operator` 3.4.0 | Operator pentru CR-uri Elasticsearch/Kibana/Logstash |
| 0 explicit | `strimzi` | `messaging` | Helm `strimzi/strimzi-kafka-operator` 0.47.0 | Operator Kafka |
| 0 explicit | `cloudnative-pg` | `data` | Helm `cloudnative-pg/cloudnative-pg` 0.22.1 | Operator Postgres (CR `Cluster`) |
| 0 explicit | `keycloak-operator` | `auth` | raw manifests din `keycloak/keycloak-k8s-resources` 26.1.4 | Operator + CR-uri Keycloak/Realm |
| 0 explicit | `reflector` | `reflector` | Helm `emberstack/reflector` 9.1.21 | Replică Secret/ConfigMap cross-namespace |
| 1 explicit | `cert-manager-issuers` | `cert-manager` | path repo `infra/cert-manager-issuers` | `ClusterIssuer` Let's Encrypt prod (HTTP01) |
| 1 explicit | `kube-prometheus-stack` | `monitoring` | Helm `prometheus-community/kube-prometheus-stack` 65.5.0 | Prometheus + Alertmanager + node/state metrics (Grafana dezactivat) |
| 1 explicit | `grafana-operator` | `monitoring` | OCI `ghcr.io/grafana/helm-charts/grafana-operator` v5.16.0 | Operator + CR-uri Grafana/Dashboard/Datasource |
| 2 explicit | `elasticsearch` | `elastic-system` | path repo `infra/elasticsearch` | CR `Elasticsearch` (1 nod, 10Gi storage) |

## Regula sync-wave

Wave-uri folosite în acest repo:

- **0** = operator (instalează CRD-uri)
- **1** = CR cluster-scoped care depinde de CRD (ex: ClusterIssuer)
- **2** = CR namespaced care depinde de operator ready (ex: Elasticsearch)
- **3+** = CR-uri care depind de alte CR-uri ready (Kibana → Elasticsearch ready) — încă nu e folosit aici

## Cum adaugi un Application nou

1. Creează `argo-apps/infra-<nume>.yaml` (urmează pattern-ul Applications existente: multi-source pentru Helm, single-source pentru manifeste raw)
2. *(dacă e Helm)* Creează `infra/<nume>/values.yaml`
3. *(dacă are CR-uri)* Creează Application separat `argo-apps/infra-<nume>-cr.yaml` cu wave mai mare
4. Commit + push → ArgoCD detectează automat

## Debug Application stuck

```bash
# Lista tuturor Applications și starea lor
kubectl -n argocd get app

# Detalii pe o Application specifică
kubectl -n argocd describe app <nume>

# Forțează refresh (citește repo din nou)
kubectl -n argocd annotate app <nume> argocd.argoproj.io/refresh=hard --overwrite
```

În UI: `DIFF` arată ce diferă între git și cluster, `EVENTS` arată erorile sync.

## Capcane

- **`OutOfSync` la chart-uri mari** (cert-manager, kube-prometheus-stack, ECK) → adaugă `ServerSideApply=true` în `syncOptions`
- **CR aplicat înainte de CRD** → setează sync-wave: CR > operator
- **Helm OCI fără prefix `oci://`** → ArgoCD nu rezolvă chart-ul. Repo-uri OCI necesită `repoURL: oci://<host>/<path>`
- **Repo gitops nu se actualizează** → în ArgoCD: `Application → REFRESH (HARD)` sau anotare `refresh=hard`
