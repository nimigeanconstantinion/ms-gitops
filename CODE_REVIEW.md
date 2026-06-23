# Code Review — Keycloak & Elasticsearch

Review pe `infra/keycloak/` și `infra/elasticsearch/` (+ kibana, filebeat) la commit `46c5c93`.
Nimic nu a fost modificat — doar diagnostic + fix propus.

| # | Componentă | Severitate | Status |
|---|---|---|---|
| 1 | Keycloak — Ingress duplicat | 🔴 Blocker (sync fail) | Root cause confirmat |
| 2 | Keycloak — ServiceMonitor scheme | 🔴 Blocker (sync fail) | Root cause confirmat |
| 3 | Elasticsearch | 🟡 Synced + stuck `Progressing` | Config diff + pași diagnostic |
| 4 | Filebeat — hostPath containerd | 🟠 Observație | Posibil „0 logs” pe K3s |
| 5 | Gap analysis vs referință | 🟢 Parity | Ce trebuie adăugat (Pas 5/5) |

---

## Pas 1/4 — Keycloak: Ingress duplicat 🔴

**Eroare**
```
admission webhook "validate.nginx.ingress.kubernetes.io" denied the request:
host "auth.icode.mywire.org" and path "/" is already defined in ingress auth/keycloak-ingress
```

**Diagnostic**
Operatorul Keycloak creează automat un Ingress propriu numit `keycloak-ingress` (derivat din `spec.hostname`). Tu mai ai și un Ingress manual numit `keycloak`. Două obiecte Ingress cu același `host + path /` în namespace-ul `auth` → nginx admission webhook respinge al doilea.

**Dovada**

| Sursă | Ce produce |
|---|---|
| `infra/keycloak/keycloak.yaml:29-31` (`spec.hostname`) | Operator generează `keycloak-ingress` |
| `infra/keycloak/keycloak.yaml:49-75` (Ingress manual) | `keycloak`, același host + `/` |

```bash
kubectl -n auth get ingress
# vei vedea AMBELE: keycloak  ȘI  keycloak-ingress  pe auth.icode.mywire.org
```

**Fix propus** (NU aplicat) — dezactivează ingress-ul operatorului, păstrează-l pe al tău (al tău are annotations cert-manager + backend HTTPS pe care le vrei):

```yaml
# infra/keycloak/keycloak.yaml, în spec:
  ingress:
    enabled: false
```

> Alternativă: ștergi Ingress-ul manual și configurezi `spec.ingress` din CR-ul Keycloak. Nu recomand — pierzi annotations cert-manager / backend-protocol HTTPS / proxy-buffer-size.

---

## Pas 2/4 — Keycloak: ServiceMonitor scheme 🔴

**Eroare**
```
ServiceMonitor.monitoring.coreos.com "keycloak" is invalid:
spec.endpoints[0].scheme: Unsupported value: "HTTP": supported values: "http", "https"
```

**Diagnostic**
CRD-ul ServiceMonitor validează `scheme` ca enum lowercase. `HTTP` nu e acceptat.

**Dovada** — `infra/keycloak/servicemonitor.yaml:15`
```yaml
      scheme: HTTP    # ← trebuie lowercase
```

**Fix propus** (NU aplicat)
```yaml
      scheme: http
```

---

## Pas 3/4 — Elasticsearch 🟡 (Synced + stuck `Progressing`)

**Simptom ArgoCD:** `elasticsearch` (ns `logging`) → STATUS `Synced`, HEALTH `Progressing` (serverside-applied). CR-ul a fost aplicat, dar ECK nu-l duce la `Ready/green` → podul nu devine Ready.

Manifestul `infra/elasticsearch/elasticsearch.yaml` e OK pe gotcha-urile uzuale ECK:
- ✅ `requests.memory == limits.memory` (2Gi) — evită OOMKill din rescheduling
- ✅ heap = 50% din container (`-Xms1g -Xmx1g` la 2Gi)
- ✅ `node.store.allow_mmap: false` — nu cere `vm.max_map_count` pe K3s

**Config diff vs referința care ajunge `green`** (`car-platform-sync-gitops/infra/eck-stack/elasticsearch.yaml`):

| Câmp | Referință (green) | CTIN (Progressing) | Risc |
|---|---|---|---|
| `version` | `8.18.7` | `8.15.3` | mic |
| `node.roles` | absent (default = toate) | listă explicită (`ml`, `transform`...) | mic |
| `securityContext` container | **absent** (ECK îl pune singur) | `runAsNonRoot` + `capabilities: drop: [ALL]` | 🟠 prim suspect — poate bloca bootstrap |
| `http.tls.selfSignedCertificate` | absent | `disabled: false` | mic |

Referința lasă ECK să-și gestioneze securityContext-ul. CTIN îl suprascrie cu `drop: [ALL]` + `runAsNonRoot` pe containerul `elasticsearch` (`infra/elasticsearch/elasticsearch.yaml:33-39`) — cel mai probabil motiv pentru un pod care nu ajunge `Ready`.

Ca să confirm root cause am nevoie de starea reală a podului. Rulează pe server2:

```bash
kubectl -n logging get elasticsearch
kubectl -n logging get pods -l elasticsearch.k8s.elastic.co/cluster-name=elasticsearch
kubectl -n logging describe elasticsearch elasticsearch | tail -40
kubectl -n logging logs elasticsearch-es-default-0 --tail=80
kubectl -n logging get events --sort-by=.lastTimestamp | tail -30
```

**Suspecți probabili pe server2** (de confirmat cu output-ul de mai sus):

| Simptom | Cauză tipică | Verificare |
|---|---|---|
| Pod `Pending` | RAM insuficientă (ES 2Gi + Kibana 1Gi + Keycloak 1Gi pe un singur nod) → **config OK, infra problem** | `kubectl describe pod ... \| grep -A3 Events` |
| PVC `Pending` | `storageClassName: local-path` lipsă / alt nume pe server2 | `kubectl get sc` |
| `CrashLoopBackOff` / `Error` la boot | securityContext `drop: [ALL]` blochează init/bootstrap | `kubectl logs ...` |
| OOMKilled | heap > RAM disponibil | `kubectl logs ...` → `OutOfMemoryError` |

> Dacă podul e `Pending` → e RAM/PVC (nu configul). Dacă e `CrashLoop`/`Error` la pornire → scoate securityContext-ul custom și lasă ECK-ul default (ca în referință).

---

## Pas 4/4 — Filebeat: hostPath pe K3s 🟠 (observație, nu blochează sync)

`infra/filebeat/filebeat.yaml` montează `/var/lib/docker/containers`. K3s folosește **containerd**, nu Docker — calea aia nu există, deci montarea e goală. Log collection merge prin symlink-urile din `/var/log/containers` + `/var/log/pods` (deja montate), dar pe unele setup-uri symlink-urile trimit spre `/var/lib/rancher/k3s/agent/containerd/...` care NU e montat → Filebeat citește symlink rupt = „0 logs”.

**De verificat după ce ES e green:**
```bash
kubectl -n logging logs -l beat.k8s.elastic.co/name=filebeat --tail=50 | grep -i "harvester\|error\|permission"
```
Dacă apar `file not found` pe target-ul symlink-ului → adaugă mount pentru `/var/lib/rancher/k3s/agent/containerd/io.containerd.grpc.v1.cri/...`.

---

## Pas 5/5 — Gap analysis: ce trebuie adăugat ca să ajungă la nivelul referinței

Referință: `practice/car-platform-sync-gitops`. Mai jos = ce există acolo și lipsește din `constantin-gitops`, ca să atingi parity.

### A. Operatori instalați FĂRĂ workload (de completat — prioritate maximă)

| Lipsă | Ai deja | Trebuie adăugat | Sursă referință |
|---|---|---|---|
| **Kafka cluster** | operator `strimzi` | CR `Kafka` + topics | `infra/kafka/` + `argo-apps/infra-kafka.yaml` |
| **Kafka UI** | — | deployment + ingress | `infra/kafka-ui/` + `argo-apps/infra-kafka-ui.yaml` |
| **Keycloak realm** | operator `keycloak` | import realm (`KeycloakRealmImport` sau crossplane-config) | `argo-apps/infra-keycloak-realms.yaml` |

> Strimzi și Keycloak operator rulează idle acum — instalate dar fără niciun obiect de gestionat.

### B. Componente infra lipsă

| Lipsă | Rol | Sursă referință | Necesită? |
|---|---|---|---|
| **kibana-ingress** | acces Kibana din afară (acum doar port-forward) | `infra/eck-stack/kibana-ingress.yaml` | ✅ da |
| `crossplane` + `crossplane-keycloak` + `-config` | provisioning declarativ realm Keycloak | `infra/crossplane*/` | opțional (ai operator direct) |
| `moco` | MySQL operator | `infra/moco/` | doar dacă ai servicii pe MySQL |
| `mongodb-operator` | MongoDB | `infra/mongodb-operator/` | doar dacă ai servicii pe Mongo |
| `databases` | CR-uri DB generice (CNPG clusters etc.) | `infra/databases/` | parțial — ai doar `postgres-keycloak` |

### C. Aplicații de business

| Lipsă | Rol | Sursă referință |
|---|---|---|
| `apps/mycodeschool` | microserviciile efective | `apps/mycodeschool/` |
| `scripts/` | helper scripts (build/push/bootstrap) | `scripts/` |

### Prioritizare pentru parity

1. **B → kibana-ingress** (rapid, deblochează accesul la logs).
2. **A → Keycloak realm** (operator inutil fără realm).
3. **A → Kafka CR + UI** (operator inutil fără cluster).
4. **B opțional** (crossplane/moco/mongo) — doar dacă apps-urile le cer.
5. **C → apps** (după ce infra e completă și verde).

---

## Recap ordine de aplicare

1. Fix #2 (scheme `http`) — trivial, deblochează ServiceMonitor.
2. Fix #1 (`ingress.enabled: false`) — deblochează sync Keycloak.
3. Diagnostic Pas 3 (pod ES) → confirmă RAM/PVC vs securityContext.
4. #4 (filebeat) doar după ce ES e `green`.
5. Pas 5 — adaugă în ordine: kibana-ingress → keycloak realm → kafka → apps.
