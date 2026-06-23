# Soluții — monitoring stack (2026-06-18)

Code review pe `kube-prometheus-stack`. Self-contained: copy-paste, commit, push, ArgoCD reconciliază.

**Ordine recomandată**: M1+M2 (doc) → M5 (safety) → M4+M6 (cleanup) → M3 (alerts routing).

---

## M1+M2 — Doc rot major pe Grafana

Grafana e **embedded și activă** în kube-prometheus-stack (commit `2817ec5` migrare grafana-operator → embedded), dar README-urile încă vorbesc de operator inexistent.

### M1.a — `infra/kube-prometheus-stack/README.md`

**Linia 11** (header tabel):
```diff
- | Grafana inclusă | ❌ DEZACTIVATĂ (gestionată separat prin grafana-operator) |
+ | Grafana inclusă | ✅ EMBEDDED (Ingress: grafana.icode.mywire.org, admin via SealedSecret) |
```

**Linia 86** (secțiunea Dashboard-uri Grafana):
```diff
- Sunt gestionate prin **grafana-operator** (separat) — vezi `infra/grafana-operator/README.md`. Dashboards comunitate (ID-uri de pe grafana.com): 315 (K8s cluster), 1860 (node exporter), 12114 (K8s deployment).
+ Adaugă ConfigMap cu label `grafana_dashboard: "1"` în orice namespace → sidecar-ul Grafana îl încarcă automat. Dashboards comunitate utile (import via UI Grafana, ID de pe grafana.com): 315 (K8s cluster), 1860 (node exporter), 12114 (K8s deployment).
```

**Adaugă tabel componente livrate** (înlocuiește linia 21 — adaugă Grafana):
```diff
  | prometheus-node-exporter | Metrici noduri (CPU/mem/disk/network) |
+ | Grafana | UI dashboards, embedded — ingress https://grafana.icode.mywire.org |
  | CRDs | ServiceMonitor, PodMonitor, PrometheusRule, AlertmanagerConfig |
```

### M1.b — `infra/README.md`

**Liniile 22-26** (catalog) — șterge linia grafana-operator (folder inexistent):
```diff
  | `kube-prometheus-stack/` | `kube-prometheus-stack` | Helm values | `monitoring` |
- | `grafana-operator/` | `grafana-operator` | Helm values | `monitoring` |
  | `strimzi/` | `strimzi` | Helm values | `messaging` |
```

### M1.c — `apps/README.md`

**Liniile 89-93** (tabel ordine operatori):
```diff
  | 1 | `kube-prometheus-stack` | operator + CR-uri | — |
- | 1 | `grafana-operator` | operator | — |
  | 2 | `elasticsearch` | CR (Elasticsearch) | `eck-operator` |
  | 2 | `postgres-keycloak` | CR (CNPG Cluster) | `cloudnative-pg` |
- | 2 | `grafana` | CR (Grafana + dashboards) | `grafana-operator` |
```

**Linia 111** (tabel namespace):
```diff
- | `monitoring` | kube-prometheus-stack + grafana-operator + Grafana CR + dashboards | Operator + CR-uri (observability) |
+ | `monitoring` | kube-prometheus-stack (Prometheus + Alertmanager + Grafana + exporters) | Operator + CR-uri (observability) |
```

### M1.d — `argo-apps/README.md`

Verifică să nu fi rămas vreo referință la `grafana-operator`:
```bash
grep -n "grafana-operator" argo-apps/README.md
# Dacă găsești → șterge linia
```

```bash
git add infra/kube-prometheus-stack/README.md infra/README.md apps/README.md argo-apps/README.md
git commit -m "docs(monitoring): align README with Grafana embedded (drop grafana-operator refs)"
```

---

## M5 — Prometheus `retentionSize` (safety high-water-mark)

`retention: 7d` + `storage: 10Gi` fără `retentionSize` → dacă scraping-ul crește (mai multe ServiceMonitor), PVC se umple înainte de 7d → Prometheus OOM/crash.

**Fișier**: `infra/kube-prometheus-stack/values.yaml`

```diff
  prometheus:
    prometheusSpec:
      replicas: 1
      retention: 7d
+     retentionSize: "8GiB"   # high-water-mark sub 10Gi storage
      resources:
```

Regula: `retentionSize` ≈ 80% din `storage.requests` (lasă headroom pentru compaction + WAL).

```bash
git add infra/kube-prometheus-stack/values.yaml
git commit -m "fix(prometheus): add retentionSize safety net under 10Gi PVC"
```

---

## M4 — Sidecar dashboards folder

`/tmp/dashboards` se șterge la container restart. Standard e sub PVC persistent.

**Fișier**: `infra/kube-prometheus-stack/values.yaml`

```diff
    sidecar:
      dashboards:
        enabled: true
        label: grafana_dashboard
        labelValue: "1"
        searchNamespace: ALL
-       folder: /tmp/dashboards
+       folder: /var/lib/grafana/dashboards
```

Sidecar oricum re-fetch din ConfigMaps, dar locația standard = previzibilitate + persistent între reload-uri.

---

## M6 — `directory.include` limitativ în Application

`argo-apps/infra-kube-prometheus-stack.yaml` selectează doar 1 fișier hardcodat — dacă mai adaugi un SealedSecret în `sealed-secrets/`, **nu se va sync**.

**Fișier**: `argo-apps/infra-kube-prometheus-stack.yaml`

```diff
    - repoURL: https://github.com/nimigeanconstantinion/ms-gitops.git
      targetRevision: master
      path: infra/kube-prometheus-stack/sealed-secrets
-     directory:
-       include: "grafana-admin-sealed.yaml"
+     directory:
+       include: "*.yaml"
```

Acum orice fișier `*.yaml` din `sealed-secrets/` e sync-uit automat. Pregătit pentru M3 (Discord webhook sealed-secret).

```bash
git add argo-apps/infra-kube-prometheus-stack.yaml infra/kube-prometheus-stack/values.yaml
git commit -m "refactor(monitoring): sidecar folder standard + sealed-secrets *.yaml glob"
```

---

## M3 — Alertmanager fără routing (silent failure)

Alertmanager rulează gol → alertele se duc în vid. Pentru lab e tolerabil, dar consumi 50m CPU + 64Mi RAM degeaba.

### Pas 1 — SealedSecret cu webhook Discord

Discord channel → Setări → Integrări → Webhook-uri → New Webhook → Copy URL.

```bash
# Creează Secret raw temporar (NU committed)
kubectl create secret generic discord-webhook \
  --namespace monitoring \
  --from-literal=url='https://discord.com/api/webhooks/XXX/YYY' \
  --dry-run=client -o yaml > /tmp/discord-raw.yaml

# Sealed cu cheia publică din cluster
kubeseal --controller-namespace kube-system --format yaml \
  < /tmp/discord-raw.yaml \
  > infra/kube-prometheus-stack/sealed-secrets/discord-webhook-sealed.yaml

rm /tmp/discord-raw.yaml
```

### Pas 2 — `AlertmanagerConfig` CR

**Fișier nou**: `infra/kube-prometheus-stack/alertmanager-config.yaml`

```yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: default
  namespace: monitoring
  labels:
    # Trebuie să matche cu alertmanagerConfigSelector din kube-prometheus-stack chart
    alertmanagerConfig: default
spec:
  route:
    receiver: discord
    groupBy: ["alertname", "namespace"]
    groupWait: 30s
    groupInterval: 5m
    repeatInterval: 4h
    routes:
      - matchers:
          - name: severity
            value: critical
        receiver: discord
        groupWait: 0s
        repeatInterval: 1h

  receivers:
    - name: discord
      webhookConfigs:
        - urlSecret:
            name: discord-webhook
            key: url
          sendResolved: true
```

### Pas 3 — Update Application să sync și manifestele raw

Adaugă în `argo-apps/infra-kube-prometheus-stack.yaml` un al patrulea source (sau extinde `sealed-secrets` path → mută `alertmanager-config.yaml` în acel folder):

**Variantă simplă** — pune `alertmanager-config.yaml` în `infra/kube-prometheus-stack/sealed-secrets/` (cu glob `*.yaml` din M6, va fi sync-uit automat).

### Pas 4 — Activează selectorul în values

**Fișier**: `infra/kube-prometheus-stack/values.yaml`

```diff
  alertmanager:
    alertmanagerSpec:
      replicas: 1
+     # Discover AlertmanagerConfig CR-uri din toate namespace-urile
+     alertmanagerConfigSelector:
+       matchLabels:
+         alertmanagerConfig: default
+     alertmanagerConfigMatcherStrategy:
+       type: None
      resources:
```

### Pas 5 — Test alertă

```bash
# Forțează o alertă manuală
kubectl -n monitoring exec -it alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  amtool alert add testalert severity=critical --alertmanager.url=http://localhost:9093

# Discord channel ar trebui să primească mesaj în <30s
```

```bash
git add infra/kube-prometheus-stack/{sealed-secrets/discord-webhook-sealed.yaml,alertmanager-config.yaml,values.yaml}
git commit -m "feat(alerting): Discord webhook + AlertmanagerConfig default route"
```

---

## Bonus — ServiceMonitor pentru operatorii existenți

Patru operatori expose metrici dar nu sunt scrape-uite. Fiecare = 1 yaml.

### CNPG Postgres

**Fișier**: `infra/cloudnative-pg/servicemonitor.yaml`

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: cnpg-controller
  namespace: data
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: cloudnative-pg
  endpoints:
    - port: metrics
      interval: 30s
```

CNPG Cluster CR expune metrici per-instanță automat dacă chart-ul are `monitoring.enablePodMonitor: true` (verifică în values.yaml CNPG).

### Strimzi Kafka

**Fișier**: `infra/strimzi/podmonitor.yaml`

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: strimzi-cluster-operator
  namespace: messaging
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      strimzi.io/kind: cluster-operator
  podMetricsEndpoints:
    - port: http
      path: /metrics
```

### ECK Operator

**Fișier**: `infra/eck-operator/servicemonitor.yaml`

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: eck-operator
  namespace: logging
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      control-plane: elastic-operator
  endpoints:
    - port: metrics
      interval: 30s
```

### Keycloak

Keycloak operator nu expune metrici nativ — necesită config în `Keycloak` CR:
```yaml
spec:
  features:
    enabled:
      - token-exchange
  additionalOptions:
    - name: metrics-enabled
      value: "true"
    - name: health-enabled
      value: "true"
```

+ ServiceMonitor:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: keycloak
  namespace: auth
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app: keycloak
  endpoints:
    - port: http
      path: /metrics
      scheme: HTTP
```

---

## Sinteză priorități

| ID | Effort | Impact |
|---|---|---|
| M1+M2 doc cleanup | 5 min, 4 fișiere | elimină confuzie |
| M5 retentionSize | 1 linie | safety net Prometheus |
| M4 dashboards folder | 1 linie | standardizare |
| M6 `include` glob | 1 linie | pregătire M3 |
| M3 Alertmanager + Discord | 4 fișiere, 20 min | rezolvi silent failure |
| Bonus ServiceMonitors | 4 yaml × 5 min | metrici reale CNPG/Strimzi/ECK/KC |

**Total minim recomandat (M1-M6)**: ~30 min de muncă, repo aliniat + Prometheus protejat + alertele funcționale.
