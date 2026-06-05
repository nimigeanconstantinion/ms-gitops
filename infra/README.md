# `infra/` — values + manifeste pentru infrastructură cluster-wide

Fiecare sub-folder corespunde unei `Application` din `argo-apps/infra-<nume>.yaml`.

## Convenție

| Tip folder | Conține |
|---|---|
| `<nume>/values.yaml` | Override-uri Helm pentru chart-uri Helm (citite prin `$values/infra/<nume>/values.yaml`) |
| `<nume>/*.yaml` (fără `values.yaml`) | Manifeste raw YAML aplicate direct ca `path: infra/<nume>` (CR-uri, ClusterIssuer, etc.) |

## Catalog

| Folder | Application | Tip | Namespace |
|---|---|---|---|
| `nginx-ingress/` | `nginx-ingress` | Helm values | `ingress-nginx` |
| `sealed-secrets/` | `sealed-secrets` | Helm values | `kube-system` |
| `cert-manager/` | `cert-manager` | Helm values | `cert-manager` |
| `cert-manager-issuers/` | `cert-manager-issuers` | raw manifests (ClusterIssuer) | `cert-manager` |
| `eck-operator/` | `eck-operator` | Helm values | `elastic-system` |
| `elasticsearch/` | `elasticsearch` | raw manifests (CR) | `elastic-system` |
| `kube-prometheus-stack/` | `kube-prometheus-stack` | Helm values | `monitoring` |
| `grafana-operator/` | `grafana-operator` | Helm values | `monitoring` |
| `strimzi/` | `strimzi` | Helm values | `messaging` |
| `cloudnative-pg/` | `cloudnative-pg` | Helm values | `data` |
| `reflector/` | `reflector` | Helm values | `reflector` |

> `keycloak-operator` nu apare aici — folosește **manifeste raw direct din GitHub upstream** (`keycloak/keycloak-k8s-resources`), nu chart Helm. Vezi `argo-apps/infra-keycloak-operator.yaml`.

## Modifică o configurație

```bash
# 1. Editează values
nano infra/<componenta>/values.yaml

# 2. Commit + push
git add infra/<componenta>/values.yaml
git commit -m "tune <componenta> resources"
git push

# 3. ArgoCD detectează drift în ~3 minute, sau forțează refresh:
kubectl -n argocd annotate app <componenta> argocd.argoproj.io/refresh=hard --overwrite
```

## Verifică o componentă

```bash
# Application în UI ArgoCD?
kubectl -n argocd get app <componenta>

# Pod-uri pornite?
kubectl -n <namespace> get pods

# Logs la primul pod:
kubectl -n <namespace> logs $(kubectl -n <namespace> get pod -o jsonpath='{.items[0].metadata.name}') --tail=50
```

## Adaugă componentă nouă

Vezi exemplele existente ca template. Pași:
1. `argo-apps/infra-<nume>.yaml` — Application
2. `infra/<nume>/values.yaml` (Helm) sau `infra/<nume>/*.yaml` (raw)
3. Commit + push → ArgoCD creează Application-ul automat
