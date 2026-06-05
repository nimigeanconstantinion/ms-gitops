# grafana-operator

Operator pentru CR-uri Grafana (`Grafana`, `GrafanaDashboard`, `GrafanaDatasource`, `GrafanaContactPoint`, `GrafanaNotificationPolicy`).

| | |
|---|---|
| Application | `argo-apps/infra-grafana-operator.yaml` |
| Chart | `grafana/grafana-operator` v5.16.0 (OCI registry) |
| Namespace | `monitoring` |
| Wave | 1 |

## 🔴 BUG critic curent (vezi CODE_REVIEW.md)

`repoURL: ghcr.io/grafana/helm-charts` — **lipsă prefix `oci://`**. Sync va eșua cu `unable to fetch chart`.

**Fix**:
```yaml
- repoURL: oci://ghcr.io/grafana/helm-charts
```

## CRD-uri principale

- `Grafana` — deploy instanță Grafana
- `GrafanaDashboard` — dashboard YAML/JSON (versionat în git)
- `GrafanaDatasource` — datasource (Prometheus, Loki, Tempo, etc.)
- `GrafanaContactPoint` — destinație alerts
- `GrafanaNotificationPolicy` — routing alerts

## Verify (după fix oci://)

```bash
kubectl -n monitoring get pods -l app.kubernetes.io/name=grafana-operator
kubectl get crd | grep grafana
```

## De ce separat de kube-prometheus-stack?

Pattern profesional: chart `kube-prometheus-stack` poate include Grafana, dar:
- Dashboard-uri în git (versionate, code-review)
- Datasource-uri ca CR (gestionate de Operator, nu Helm values)
- Multiple instances Grafana per echipă/scop (logs vs metrics vs APM)

→ Operator separat dă control granular.

## Lipsuri actuale

Operator instalat dar **fără CR-uri**:
- ❌ `Grafana` (deploy instanța)
- ❌ `GrafanaDatasource` Prometheus
- ❌ `GrafanaDashboard`-uri (K8s 315, Node 1860, Postgres, Kafka, etc.)
- ❌ Ingress `grafana.<domeniu>`

## Next: CR Grafana instance

```yaml
# infra/grafana/grafana.yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: grafana
  namespace: monitoring
  labels:
    dashboards: "grafana"
spec:
  config:
    server:
      root_url: "https://grafana.<domeniu>"
    auth:
      disable_login_form: "false"
    security:
      admin_user: admin
      admin_password: <din-secret>
  deployment:
    spec:
      replicas: 1
```

Plus Application `argo-apps/infra-grafana.yaml` wave 3 (după operator + Prometheus ready).
