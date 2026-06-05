# Migrare Grafana: Operator → reactivare în kube-prometheus-stack

## De ce această abordare

Chart-ul `kube-prometheus-stack` (deja instalat) include Grafana ca **sub-chart embedded**. Constantin a dezactivat-o explicit (`grafana.enabled: false`) și a încercat să gestioneze separat prin Grafana Operator. Asta a generat:
- Bug `oci://` lipsă la `grafana-operator` Application
- Conflict Secret plain vs SealedSecret în `infra/grafana/secrets/`
- 2 Applications de gestionat în loc de 1
- Necesar de configurat manual datasource Prometheus

**Soluția**: reactivează Grafana în `kube-prometheus-stack` și șterge complet operatorul + CR-urile custom.

| Aspect | Acum (Operator) | După (reactivare) |
|---|---|---|
| Applications Grafana | 2 (`grafana-operator` + `grafana`) | **0 noi** — doar values updated |
| Fișiere YAML noi | 5+ | **0** (doar edit `values.yaml` + 1 SealedSecret) |
| Datasource Prometheus | Manual via CR `GrafanaDatasource` | **Auto-configurat** (același namespace) |
| Dashboards default K8s | Manual import | **~20 dashboards incluse** (apiserver, kubelet, nodes, persistentvolumes, scheduler, statefulset, ...) |
| Probabilitate `OutOfSync` | Înaltă (CR + Secret conflict + OCI) | Minimă |
| Lifecycle Grafana | Independent | Cuplat de upgrade-ul chart-ului monitoring |

## Pre-migration — backup ce ai (opțional)

Dacă ai dashboards custom create manual în UI:

```bash
# Notează parola actuală admin
kubectl -n monitoring get secret grafana-admin-credentials \
  -o jsonpath='{.data.GF_SECURITY_ADMIN_PASSWORD}' | base64 -d
echo

# Export dashboards via API
kubectl -n monitoring port-forward svc/grafana-service 3000:3000 &
sleep 2
curl -s -u admin:<parola-de-mai-sus> http://localhost:3000/api/search?type=dash-db \
  | jq -r '.[].uid' \
  | while read uid; do
      curl -s -u admin:<parola> http://localhost:3000/api/dashboards/uid/$uid \
        > backup-dashboard-$uid.json
    done
kill %1
```

Le re-importi după migrare prin ConfigMap cu label `grafana_dashboard: "1"`.

## Pasul 1 — Generează SealedSecret pentru admin password

```bash
cd ~/Documents/proiecte-elevi-in-curs/ctin-platform/ctin-gitops

# Creează Secret plain LOCAL (NU commit!)
cat > /tmp/grafana-admin-raw.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin-credentials
  namespace: monitoring
type: Opaque
stringData:
  admin-user: admin
  admin-password: "ParolaTaSigura!"
EOF

# Sealează
kubeseal --controller-namespace kube-system \
         --controller-name sealed-secrets-controller \
         --format yaml \
         < /tmp/grafana-admin-raw.yaml \
         > infra/kube-prometheus-stack/grafana-admin-sealed.yaml

# Cleanup
rm /tmp/grafana-admin-raw.yaml
```

## Pasul 2 — Adaugă SealedSecret-ul în Application

`infra/kube-prometheus-stack/grafana-admin-sealed.yaml` trebuie aplicat ÎNAINTE ca Grafana să pornească. Cea mai simplă variantă: include-l ca a 3-a sursă în Application.

Edit `argo-apps/infra-kube-prometheus-stack.yaml` — adaugă a 3-a sursă:

```yaml
sources:
  - repoURL: https://prometheus-community.github.io/helm-charts
    chart: kube-prometheus-stack
    targetRevision: 65.5.0
    helm:
      releaseName: kube-prometheus-stack
      valueFiles:
        - $values/infra/kube-prometheus-stack/values.yaml

  - repoURL: https://github.com/nimigeanconstantinion/ms-gitops.git
    targetRevision: master
    ref: values

  # ⬇ Adăugare nouă: SealedSecret pentru Grafana admin
  - repoURL: https://github.com/nimigeanconstantinion/ms-gitops.git
    targetRevision: master
    path: infra/kube-prometheus-stack/sealed-secrets
    directory:
      include: "grafana-admin-sealed.yaml"
```

Și mută fișierul:

```bash
mkdir -p infra/kube-prometheus-stack/sealed-secrets
mv infra/kube-prometheus-stack/grafana-admin-sealed.yaml \
   infra/kube-prometheus-stack/sealed-secrets/
```

> Alternativă mai curată: Application separat `infra-grafana-secrets.yaml` cu wave 0 explicit, fără să modifici Application kube-prometheus-stack. Folosește dacă vrei să separi clar life-cycle Secret-urilor.

## Pasul 3 — Reactivează Grafana în values

Edit `infra/kube-prometheus-stack/values.yaml` — schimbă secțiunea Grafana:

```yaml
# ===== GRAFANA =====
# Activat — Grafana embedded din kube-prometheus-stack
grafana:
  enabled: true

  # Admin user/pass din SealedSecret
  admin:
    existingSecret: grafana-admin-credentials
    userKey: admin-user
    passwordKey: admin-password

  # Storage persistent — dashboards salvate manual, plugins, state
  persistence:
    enabled: true
    type: pvc
    storageClassName: local-path
    size: 5Gi

  # Sidecar care încarcă dashboards/datasources din ConfigMaps cu label
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      labelValue: "1"
      searchNamespace: ALL
      folder: /tmp/dashboards
    datasources:
      enabled: true
      label: grafana_datasource
      labelValue: "1"
      searchNamespace: ALL

  # Resources
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

  # Ingress + TLS auto via cert-manager
  ingress:
    enabled: true
    ingressClassName: nginx
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod
    hosts:
      - grafana.icode.mywire.org
    tls:
      - hosts:
          - grafana.icode.mywire.org
        secretName: grafana-tls

  # Service intern — acces doar prin Ingress
  service:
    type: ClusterIP

  # Default config Grafana
  grafana.ini:
    server:
      root_url: "https://grafana.icode.mywire.org"
    auth.anonymous:
      enabled: false

  # Datasources și dashboards EMBEDDED — vin gratis cu chart-ul
  # (nu trebuie să le configurezi manual; kube-prometheus-stack le auto-configurează)
```

## Pasul 4 — Șterge artifacts vechi din Grafana Operator

```bash
# Application-urile vechi
git rm argo-apps/infra-grafana-operator.yaml
git rm argo-apps/infra-grafana.yaml

# Folderele
git rm -rf infra/grafana-operator/
git rm -rf infra/grafana/
```

## Pasul 5 — Commit + push

```bash
git add infra/kube-prometheus-stack/ argo-apps/infra-kube-prometheus-stack.yaml
git commit -m "switch: grafana-operator → grafana embedded în kube-prometheus-stack"
git push
```

## Pasul 6 — Cleanup ArgoCD UI

```bash
# Verifică starea
kubectl -n argocd get app

# Application-urile vechi pot rămâne ca "ghost" — șterge manual
kubectl -n argocd delete app grafana-operator
kubectl -n argocd delete app grafana

# Forțează refresh pe kube-prometheus-stack
kubectl -n argocd annotate app kube-prometheus-stack \
  argocd.argoproj.io/refresh=hard --overwrite
```

## Pasul 7 — Verifică

```bash
# Application Synced + Healthy
kubectl -n argocd get app kube-prometheus-stack -w

# Pod Grafana rulează
kubectl -n monitoring get pods | grep grafana
# așteptat: kube-prometheus-stack-grafana-xxxxx  3/3  Running (3 containere: grafana + 2 sidecars)

# Ingress + cert TLS
kubectl -n monitoring get ingress | grep grafana
kubectl -n monitoring get certificate grafana-tls
# așteptat: Ready=True (poate dura 1-2 min pentru emitere LE)

# Secret admin sigilat OK
kubectl -n monitoring get secret grafana-admin-credentials -o yaml | grep -A 2 "data:"
# trebuie să existe admin-user și admin-password
```

## Pasul 8 — Login + verifică datasources

1. Deschide `https://grafana.icode.mywire.org`
2. Login: `admin` + parola pe care ai sealed-uit-o
3. **Configuration → Data sources** — Prometheus + Alertmanager + Loki (dacă există) apar **automat**
4. **Dashboards → Browse** — ~20 dashboards K8s default: "Kubernetes / API server", "Kubernetes / Compute Resources / Cluster", "Kubernetes / Networking / Cluster", etc.

## Pasul 9 — Adăugare dashboard custom (după caz)

Toate dashboard-urile custom se adaugă prin ConfigMap cu label. Exemplu:

```yaml
# infra/dashboards/dashboard-nginx.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: dashboard-nginx
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  nginx.json: |
    {<JSON dashboard exportat din UI sau de pe grafana.com>}
```

Plus Application separat dacă vrei multiple dashboards:

```yaml
# argo-apps/infra-dashboards.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: dashboards
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "3"
spec:
  project: default
  source:
    repoURL: https://github.com/nimigeanconstantinion/ms-gitops.git
    targetRevision: master
    path: infra/dashboards
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Sidecar-ul Grafana detectează automat ConfigMap-ul nou și încarcă dashboard-ul fără restart Grafana.

## Checklist final

- [ ] SealedSecret `grafana-admin-credentials` în repo (NU plain Secret)
- [ ] `infra/grafana-operator/` șters din repo
- [ ] `infra/grafana/` (cu plain Secret) șters din repo
- [ ] `argo-apps/infra-grafana-operator.yaml` șters
- [ ] `argo-apps/infra-grafana.yaml` șters
- [ ] `grafana.enabled: true` în `infra/kube-prometheus-stack/values.yaml`
- [ ] `grafana.admin.existingSecret: grafana-admin-credentials` configurat
- [ ] Ingress configurat în values cu cert-manager annotation
- [ ] Sidecar dashboards + datasources activat
- [ ] Application `kube-prometheus-stack` Synced + Healthy
- [ ] Pod Grafana 3/3 containers Running
- [ ] Certificate `grafana-tls` Ready
- [ ] Login UI cu parola din SealedSecret merge
- [ ] Datasource Prometheus apare automat
- [ ] Dashboards default K8s apar în Browse

## Rollback (dacă merge prost)

```bash
git revert HEAD
git push

# ArgoCD restaurează starea anterioară
# Cele 2 Applications (operator + grafana) revin
```

## Lipsuri rezolvate

| Lipsa identificată în CODE_REVIEW | Status după migrare |
|---|---|
| B1 — `oci://` lipsă la grafana-operator | ✅ Operator șters complet |
| Conflict Secret plain vs SealedSecret în `infra/grafana/secrets/` | ✅ Folder șters; SealedSecret single source |
| Parola admin plain commit-uită în git public | ⚠️ Tot e în istoria git (vezi nota mai jos) |
| Application `grafana-operator` `OutOfSync` permanent | ✅ Application șters |
| Datasource Prometheus manual via CR | ✅ Auto-configurat |
| Dashboards K8s lipsesc | ✅ ~20 default incluse |

## Notă pe securitate (parola din istoria git)

Repo `nimigeanconstantinion/ms-gitops` este **public**. Parola `StrongPassword123` rămâne în istoria git chiar și după `git rm` (commit-ul `8766144` o conține). Opțiuni:

- **Soft**: rotește doar parola activă cu cea sigilată nouă — parola veche oricum nu mai e funcțională
- **Hard**: `git filter-repo --invert-paths --path infra/grafana/secrets/grafana-secret.yaml` apoi force push (rescrie istoria; periculos dacă altcineva a clonat)
- **Recomandat**: rotește parola + comentariu în README că commit-ul X conține credential revocat

## Pattern reutilizabil

Același pattern (chart embedded + sidecar ConfigMap) funcționează pentru:
- **Loki** ca datasource (chart `grafana/loki`, datasource provisioning în values kube-prometheus-stack)
- **Tempo** la fel
- **Pyroscope** la fel

Toate au pattern de provisioning prin ConfigMap label, fără CR-uri.
