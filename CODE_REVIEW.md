# Code Review — ctin-gitops (2026-06-05)

Stare: 13 Applications, dintre care 1 cu bug critic (sync va eșua) + 2 cu bug-uri minore. Layer CR-uri 1/5 acoperit.

## 🔴 Bug-uri critice (fix înainte de orice push nou)

### B1 — `grafana-operator` repoURL fără prefix `oci://`

**Unde**: `argo-apps/infra-grafana-operator.yaml:15`

**Actual**:
```yaml
- repoURL: ghcr.io/grafana/helm-charts
  chart: grafana-operator
  targetRevision: v5.16.0
```

**Problemă**: chart-ul Grafana Operator e pe **OCI registry**. ArgoCD necesită explicit prefix `oci://` pentru a-l rezolva. Fără prefix, sync eșuează cu `unable to fetch chart`.

**Fix**:
```yaml
- repoURL: oci://ghcr.io/grafana/helm-charts
  chart: grafana-operator
  targetRevision: v5.16.0
```

**Verificare**:
```bash
kubectl -n argocd get app grafana-operator -o jsonpath='{.status.sync.status}'
# înainte: OutOfSync (cu error în UI)
# după: Synced
```

### B2 — `eck-operator` lipsă `ServerSideApply=true`

**Unde**: `argo-apps/infra-eck.yaml:32-36`

**Actual**:
```yaml
syncOptions:
  - CreateNamespace=true
```

**Problemă**: CRD-urile ECK (Elasticsearch, Kibana, Logstash, Beats, ApmServer) sunt mari. Fără `ServerSideApply` riscă `request entity too large`. Comparație: cert-manager, kube-prometheus-stack, strimzi, cnpg, keycloak-operator toate au.

**Fix**:
```yaml
syncOptions:
  - CreateNamespace=true
  - ServerSideApply=true
```

### B3 — `eck-operator` comentariu copy-paste greșit

**Unde**: `argo-apps/infra-eck.yaml:12`

**Actual**:
```yaml
# Sursa 1: Helm chart oficial Sealed Secrets
```

**Fix**:
```yaml
# Sursa 1: Helm chart oficial ECK (Elastic Cloud on Kubernetes)
```

## 🟡 Issue-uri minore (când ai timp)

### M1 — Sync-wave lipsă pe primele 4 Applications

`sealed-secrets`, `nginx-ingress`, `cert-manager`, `eck-operator` nu au anotare `sync-wave`. Toate sunt implicit wave 0, deci funcționează — dar pattern-ul tău e consistent (`reflector`, `strimzi`, `cnpg`, `keycloak-operator` toate au wave `"0"` explicit). Adaugă pentru uniformitate:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "0"
```

### M2 — Comentariu contradictoriu în `bootstrap/root.yaml:14`

**Actual**: `targetRevision: master   # SAU master — ajustează după branch-ul real al repo-ului`

Copy-paste din starter (acolo era `main # SAU master`). Acum scrie "master SAU master" — fără sens. Scoate comentariul sau pune `# branch-ul activ`.

### M3 — Documentație desincronizată

`README.md` zice "Conține DOAR" și enumeră 4 Applications — realitate 13. Referințe la `docs/`, `scripts/cleanup-cluster.sh`, `scripts/full-reset.sh`, `argocd-platform-starter/` — niciuna nu există. `GETTING_STARTED.md` Pasul 7 prezintă ClusterIssuer ca "next step manual" — deja există în repo de la commit 2.

Opțiuni: (a) regenerează README din actualul stack, (b) marchează cu un disclaimer "starter snapshot" și lasă realitatea în `argo-apps/README.md` (deja creat).

## 🟢 Pattern-uri corecte (continuă așa)

- ✅ Multi-source (`$values/...` + `ref: values`) — aplicat consistent
- ✅ Namespace pe funcție (`messaging`, `data`, `auth`) — nu pe tehnologie
- ✅ `ServerSideApply=true` pe chart-uri mari (cert-manager, kube-prometheus-stack)
- ✅ `ignoreDifferences` pe kube-prometheus-stack pentru drift cosmetic CRD `/status`
- ✅ Grafana dezactivat în kube-prometheus-stack, gestionat separat prin Grafana Operator — pattern profesional
- ✅ Elasticsearch CR cu `securityContext` riguros (`runAsNonRoot`, `drop: [ALL]`, `selfSignedCertificate`)

## 📋 Layer CR-uri (next step natural)

Ai 8 operatori instalați. Următorul layer = CR-uri care depind de ei. Ordine de impact:

| Prioritate | CR | Operator depend | Wave | Notă |
|---|---|---|---|---|
| 1 | `Kibana` | eck-operator | 3 | Vizualizare logs — UI imediat utilizabil, cere `Elasticsearch ready` |
| 2 | `Postgres Cluster` (CNPG) | cloudnative-pg | 2 | Necesar pentru Keycloak CR. `bootstrap` + storage |
| 3 | `Kafka` (KRaft, 1 broker) | strimzi | 2 | KRaft = fără ZooKeeper, mai simplu. Adaugă și `KafkaTopic` |
| 4 | `Keycloak` CR + `KeycloakRealmImport` | keycloak-operator | 3 | Depinde de Postgres ready + secret cu credențiale DB |
| 5 | `Grafana` + `GrafanaDashboard` + `GrafanaDatasource` | grafana-operator | 3 | Datasource Prometheus + dashboard-uri din community |
| 6 | `Logstash` | eck-operator | 3 | Doar dacă vrei pipeline custom — Kibana + Elasticsearch acopera 80% din cazuri |

**Pattern fișier**:
```
argo-apps/infra-<nume>-cr.yaml      ← Application separată, wave > operator
infra/<nume>-cr/<resurse>.yaml      ← CR-urile efective
```

## 🔐 Layer Secrets (după CR-uri)

`sealed-secrets-controller` rulează din primul commit, dar **nu există încă niciun SealedSecret** în repo. Va fi necesar pentru:
- Postgres Cluster (bootstrap user/parolă)
- Keycloak (admin user/parolă + DB credentials)
- Kafka SCRAM users (dacă activezi auth)

Workflow: `kubeseal` CLI pe laptop → sigilezi local → commit-uiești `SealedSecret` → controller-ul îl decriptează în cluster.

## 🌐 Layer Ingress (ultima etapă infra)

Lipsesc Ingress-urile pentru:
- ArgoCD (`argocd.<domeniu>`)
- Kibana (`kibana.<domeniu>`)
- Grafana (`grafana.<domeniu>`)
- Keycloak (`auth.<domeniu>`)
- Kafka UI (`kafka-ui.<domeniu>` — necesar Kafka UI deploy)

Pattern: fiecare cu anotare `cert-manager.io/cluster-issuer: letsencrypt-prod` → cert TLS automat.

## Sinteză

| Categorie | Stare |
|---|---|
| Operatori instalați | 8/10 (lipsesc Istio, Tempo, MOCO) |
| CR-uri layer | 1/6 (doar Elasticsearch) |
| SealedSecrets | 0 |
| Ingress per serviciu | 0 |
| Bug-uri critice | 1 (oci:// la grafana-operator) |
| Documentație sync | ~30% (README + GS din starter, neactualizate) |

**Risk #1**: la următorul deploy de la zero (`kubectl apply -f bootstrap/root.yaml` pe cluster nou), `grafana-operator` va rămâne `OutOfSync` permanent până fix oci://.

**Quick win azi**: B1+B2+B3 (3 modificări de 1 linie fiecare) + Kibana CR (10 min) = stack vizibil în browser via Kibana.
