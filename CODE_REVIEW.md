# Code Review — full repo audit

Review complet la commit `449b330`. Nimic nu a fost modificat — doar diagnostic + fix propus.
Acoperă: bootstrap, sync-waves, secrete, baze de date, Crossplane, logging (ELK), Kafka, monitoring, ingress.

## Rezolvate din review-ul precedent (scoase)

| Problemă veche | Status |
|---|---|
| Keycloak — Ingress duplicat | ✅ `spec.ingress.enabled: false` aplicat (`keycloak.yaml:16`) |
| Keycloak — ServiceMonitor `scheme: HTTP` | ✅ `scheme: http` aplicat (`servicemonitor.yaml:15`) |

## Sumar probleme curente

| # | Componentă | Severitate | Status |
|---|---|---|---|
| A | Secrete `*-raw.yaml` commise în git (parole în clar) | 🔴 Blocker security | Confirmat |
| B | `infra/databases/` orfan — niciun App nu-l sincronizează | 🔴 Blocker funcțional | Confirmat |
| C | Crossplane-keycloak nefuncțional — de aliniat la starter | 🟡 Arhitectură | Decizie: păstrăm Crossplane |
| D | `kafka-ui` host copy-paste greșit din referință | 🟠 Sync/cert fail | Confirmat |
| E | Elasticsearch + Kibana `securityContext` custom | 🟡 Posibil `Progressing` | Neschimbat |
| F | Filebeat hostPath `/var/lib/docker/containers` pe K3s | 🟠 Posibil „0 logs” | Neschimbat |
| G | Observații minore (waves, whitespace, idle operators) | 🟢 Polish | Listă |

---

## A 🔴 — Parole în clar în git history

**Diagnostic** — `.gitignore` are pattern-ul `*-secret-raw.yaml`, dar fișierele raw se numesc `*-raw.yaml` → nu se potrivesc și sunt tracked.

**Dovada** — `git ls-files | grep raw`

| Fișier | Conținut expus |
|---|---|
| `infra/databases/secrets/keycloak-db-raw.yaml` | `password: "StrongPassword123!"` |
| `infra/databases/secrets/mongodb-demo-raw.yaml` | `password: mongopassword` |
| `infra/crossplane-keycloak-config/secrets/keycloak-credentials-raw.yaml` | `credentials: keycloak` (placeholder) |

**Fix propus** (NU aplicat)
```gitignore
*-raw.yaml
```
```bash
git rm --cached infra/databases/secrets/keycloak-db-raw.yaml \
                infra/databases/secrets/mongodb-demo-raw.yaml \
                infra/crossplane-keycloak-config/secrets/keycloak-credentials-raw.yaml
```
Parolele sunt deja în history → rotește-le + re-seal după `git rm`.

---

## B 🔴 — `infra/databases/` orfan: operatori instalați degeaba

**Diagnostic** — `grep -rln "infra/databases" argo-apps/` → **niciun** Application. Folderul `infra/databases/` (4 CR-uri + secrete) nu e sincronizat de nimic.

**Consecințe**

| Resursă în `infra/databases/` | Operator instalat | Efect |
|---|---|---|
| `mysql.yaml` (`MySQLCluster`) | MOCO (wave 1) | Operator idle — CR-ul nu se aplică niciodată |
| `mongodb.yaml` (`MongoDBCommunity`) | mongodb-operator (wave 0) | Operator idle — CR-ul nu se aplică |
| `postgres-cluster.yaml` (`Cluster` demo) | CNPG (wave 0) | Cluster `demo` neimplementat |
| `keycloak-db-cluster.yaml` (`Cluster` `keycloak-pg`) | CNPG | **Duplicat** — vezi mai jos |
| `secrets/*-sealed.yaml` | sealed-secrets | SealedSecret-urile nu se aplică |

**Duplicat Keycloak Postgres** — există DOUĂ definiții de Postgres pentru Keycloak:

| Definiție | Cluster | Secret | Sincronizat? |
|---|---|---|---|
| `infra/postgres-keycloak/cluster.yaml` | `postgres-keycloak` (auto-secret `postgres-keycloak-app`, mirror Reflector → `auth`) | auto-generat CNPG | ✅ App `postgres-keycloak` (wave 2) |
| `infra/databases/keycloak-db-cluster.yaml` | `keycloak-pg` (`managed.roles` + sealed `keycloak-db-app`) | sealed | ❌ orfan |

Keycloak CR pointează pe `postgres-keycloak-rw.data.svc` cu secret `postgres-keycloak-app` (`keycloak.yaml:20,24-29`) → folosește definiția sincronizată. Deci `keycloak-db-cluster.yaml` e cod mort de pe o abordare anterioară.

**Fix propus** (NU aplicat) — alege:
- **Dacă NU ai nevoie de MySQL/Mongo/Postgres-demo acum** (apps/ e gol): șterge `infra/databases/` întreg + dezinstalează operatorii idle (`moco`, `mongodb-operator`) ca să nu consume RAM degeaba.
- **Dacă ai nevoie**: creează `argo-apps/infra-databases.yaml` (wave 2, `recurse: true`, ns `data`) care sincronizează `infra/databases/`, ȘI șterge `keycloak-db-cluster.yaml` (duplicat cu `postgres-keycloak`).

> Pe un singur nod server2 (RAM limitat) operatorii idle + clustere nefolosite = presiune RAM inutilă care poate explica `Pending`/`Progressing` la ES (vezi E).

---

## C 🟡 — Crossplane-keycloak: de aliniat la starter

**Decizie:** păstrăm Crossplane ca mecanism de realm (reconciliere continuă + drift detection). Trebuie aliniat la starterul `car-platform-sync-gitops`, unde stack-ul ajunge `Synced`.

**De ce e mort acum**

| Cauză | CTIN | Referință (Synced) |
|---|---|---|
| Credențiale placeholder | `keycloak-credentials` = `credentials: keycloak` | JSON `admin-cli` complet |
| Zero CR-uri de reconciliat | `keycloak-realms` App → `path: apps`, dar `apps/` are doar `README.md` | `apps/<app>/keycloak/realm.yaml` (CR `Realm`) |
| Mecanism dublu | `KeycloakRealmImport` în `infra/keycloak/realm-demo.yaml` | doar Crossplane |

**Fix propus** (NU aplicat) — 3 pași spre paritate:

**1. Credențiale reale** în `infra/crossplane-keycloak-config/secrets/keycloak-credentials-raw.yaml` (apoi `kubeseal` + șterge raw):
```yaml
stringData:
  credentials: |
    {
      "client_id": "admin-cli",
      "username": "<din secret keycloak-initial-admin>",
      "password": "<din secret keycloak-initial-admin>",
      "url": "http://keycloak-service.auth.svc:8080",
      "base_path": "",
      "realm": "master"
    }
```
```bash
kubectl -n auth get secret keycloak-initial-admin -o jsonpath='{.data.username}' | base64 -d
kubectl -n auth get secret keycloak-initial-admin -o jsonpath='{.data.password}' | base64 -d
kubeseal --controller-namespace kube-system --controller-name sealed-secrets-controller \
  --format yaml < infra/crossplane-keycloak-config/secrets/keycloak-credentials-raw.yaml \
  > infra/crossplane-keycloak-config/secrets/keycloak-credentials-sealed.yaml
```
> `url` = service-ul INTERN Keycloak (ns `auth`, port HTTP 8080 — `httpEnabled: true` deja setat). NU domeniul public.

**2. Realm CR Crossplane** în `apps/<app>/keycloak/realm.yaml`:
```yaml
apiVersion: realm.keycloak.crossplane.io/v1alpha1
kind: Realm
metadata:
  name: demo
spec:
  forProvider:
    realm: demo
    enabled: true
    displayName: "Demo Realm"
  providerConfigRef:
    name: keycloak-provider-config
```

**3. Șterge mecanismul dublu** — `infra/keycloak/realm-demo.yaml` (`KeycloakRealmImport`).

---

## D 🟠 — kafka-ui host străin de platformă

**Diagnostic** — `infra/kafka-ui/values.yaml:29` are host copiat verbatim din referință:
```yaml
  host: kafka-ui.aws.mycodepractice.com
```
Tot restul platformei e pe `icode.mywire.org` (server2/dynu):

| Componentă | Host |
|---|---|
| keycloak | `auth.icode.mywire.org` |
| kibana | `kibana.icode.mywire.org` |
| grafana | `grafana.icode.mywire.org` |
| argocd | `argocd.icode.mywire.org` |
| **kafka-ui** | **`kafka-ui.aws.mycodepractice.com`** ← greșit |

`aws.mycodepractice.com` e domeniul home/AWS → DNS nu rezolvă spre server2 → cert-manager nu emite cert, ingress inutil.

**Fix propus** (NU aplicat)
```yaml
  host: kafka-ui.icode.mywire.org
```
> CR-ul Kafka în sine e OK — `version: 4.2.0` + `kafka.strimzi.io/v1` (cluster + topics) sunt identice cu referința, compatibile Strimzi 0.47.

---

## E 🟡 — Elasticsearch + Kibana: securityContext custom

**Diagnostic** — ambele containere suprascriu `securityContext` cu `runAsNonRoot` + `capabilities.drop: [ALL]`:
- `infra/elasticsearch/elasticsearch.yaml:33-38`
- `infra/kibana/kibana.yaml` (același bloc)

Referința care ajunge `green` lasă ECK să-l gestioneze singur. Dacă podul ES e blocat `Progressing`/`CrashLoop`, ăsta e primul suspect (după RAM — vezi B).

**Verificare pe server2**
```bash
kubectl -n logging get elasticsearch
kubectl -n logging logs elasticsearch-es-default-0 --tail=80
kubectl -n logging describe elasticsearch elasticsearch | tail -40
kubectl get sc   # storageClassName: local-path există?
```

| Simptom | Cauză | Acțiune |
|---|---|---|
| `Pending` | RAM insuficient (ES 2Gi + Kibana 1Gi + Keycloak 1Gi + operatori idle) | curăță B → eliberează RAM |
| `CrashLoop`/`Error` la boot | securityContext `drop: [ALL]` blochează bootstrap | scoate securityContext-ul custom |
| PVC `Pending` | `local-path` lipsă/alt nume | `kubectl get sc` |

---

## F 🟠 — Filebeat hostPath pe K3s/containerd

**Diagnostic** — `infra/filebeat/filebeat.yaml` montează `/var/lib/docker/containers`. K3s folosește containerd, nu Docker → mount gol. Colectarea merge prin `/var/log/containers` + `/var/log/pods` (montate), dar pe unele setup-uri symlink-urile trimit spre `/var/lib/rancher/k3s/agent/containerd/...` care NU e montat → symlink rupt = „0 logs”.

**De verificat după ce ES e green**
```bash
kubectl -n logging logs -l beat.k8s.elastic.co/name=filebeat --tail=50 | grep -i "harvester\|error\|permission\|not found"
```
Dacă apar `file not found` → adaugă mount `/var/lib/rancher/k3s/agent/containerd/io.containerd.grpc.v1.cri/...`.

---

## G 🟢 — Observații minore (polish)

| Observație | Locație | Impact |
|---|---|---|
| Operatori idle (`moco`, `mongodb-operator`) — instalați fără workload (vezi B) | `argo-apps/infra-moco.yaml`, `infra-mongodb-operator.yaml` | RAM irosit pe server2 |
| ProviderConfig (wave 2) aplicat înainte de Keycloak (wave 3) — provider nu se conectează până Keycloak ready | `crossplane-keycloak-config` | Doar întârziere; reconciliază continuu, OK |
| Trailing whitespace pe `sync-wave: "0"  ` | mai multe `argo-apps/infra-*.yaml` | Cosmetic |
| `keycloak-realms` App: ns destinație `crossplane-system` + `path: apps` recurse, dar `apps/` gol | `argo-apps/infra-keycloak-realms.yaml` | Synced gol până adaugi Realm CR (vezi C2) |
| `reflector` App fără `ServerSideApply` | `argo-apps/infra-reflector.yaml` | OK pentru Helm mic |

---

## Ordine fix recomandată

1. **A** — security, urgent (lărgește `.gitignore`, `git rm --cached`, rotește parolele).
2. **B** — decide soarta `infra/databases/` (șterge sau wire-uiește în App) + scoate duplicatul `keycloak-pg`.
3. **D** — trivial (un host kafka-ui).
4. **C** — aliniază Crossplane la starter (creds reale → Realm CR în `apps/` → scoate `KeycloakRealmImport`).
5. **E** — după output-ul podului ES (RAM vs securityContext).
6. **F** — după ce ES e `green`.
