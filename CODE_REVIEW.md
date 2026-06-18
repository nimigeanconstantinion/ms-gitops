# Code Review — ctin-gitops (2026-06-18)

**Stare**: Toate cele 4 bug-uri critice din review-ul anterior (2026-06-16) — **REZOLVATE**. Repo-ul a evoluat curat, stack-ul de bază (operatori + ingress + cert) funcționează. Rămân **2 issue-uri minore din review-ul anterior + 3 observații noi** descoperite la analiza profundă a stack-ului ELK.

## ✅ Status fix-uri din review-ul anterior (2026-06-16)

| ID | Bug | Status | Verificare |
|---|---|---|---|
| **C1** | Parolă plain text în repo public (`grafana-admin-raw.yaml`) | ✅ Fix | Fișierul șters; doar `grafana-admin-sealed.yaml` rămas |
| **C2** | Ingress ArgoCD (HTTPS vs HTTP + service greșit) | ✅ Fix | `infra/argocd-ingress/ingress.yaml`: `name: argocd-server`, port 80, service `argocd-server` |
| **C3** | Conflict Secret + SealedSecret pe `grafana-admin-credentials` | ✅ Fix | Colateral cu C1 — doar SealedSecret rămas |
| **C4** | Logstash → ES namespace greșit | ✅ Fix | `infra/logstash/logstash.yaml:14`: `namespace: elastic-system` (corect) |

**Excelent**: progres real, code-review acționat sistematic.

## 🔬 Auto-corectare din review-ul anterior (mea culpa)

### C4 supliment — `clusterName: eck` NU trebuia scos

În review-ul anterior am recomandat ștergerea câmpului `clusterName: eck` din `elasticsearchRefs`. **Greșit.**

ECK folosește `clusterName` ca **prefix pentru env vars injectate automat** în container-ul Logstash:
- `ECK_ES_HOSTS`, `ECK_ES_USER`, `ECK_ES_PASSWORD`, `ECK_ES_SSL_CERTIFICATE_AUTHORITY`

Pipeline-ul din `logstash.yaml:42-49` referă exact aceste env vars (`${ECK_ES_HOSTS}`, etc.), deci `clusterName: eck` e **CORECT și necesar**. Fără el → variabilele nu există → pipeline crash la startup.

**Concluzie**: ai păstrat câmpul — bună decizie, ignorându-mi sugestia greșită. Lesson learned din partea mea.

## 🟡 Issue-uri rămase / noi

### M2 (din review anterior) — `argocd-ingress` Argo App fără sync-wave

**Unde**: `argo-apps/infra-argocd-ingress.yaml`

```yaml
metadata:
  name: argocd-ingress
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  # ⚠️ lipsește anotare sync-wave
```

Per convenția documentată în `apps/README.md`, Ingress-urile sunt **wave `4`** (după operatori + CR-uri + servicii). Fără anotare → default wave `0` → încearcă să creeze Ingress înainte de cert-manager → poate eșua silent la prima reconciliere.

**Fix** (1 linie):
```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "4"
```

### M3 (din review anterior) — Keycloak fără Ingress

`infra/keycloak/keycloak.yaml:23` declară:
```yaml
hostname:
  hostname: https://auth.icode.mywire.org
  strict: true
```

Cu `strict: true`, Keycloak **refuză orice request pe alt hostname** decât `auth.icode.mywire.org`. Fără Ingress → hostname-ul nu rezolvă din afară → utilizatorul vede `ERR_CONNECTION_REFUSED`.

**Fix**: vezi review-ul anterior § M3 pentru template Ingress complet.

### N1 (NOU) — Namespace inconsistent în stack-ul logging 🟡

**Drift între componente ale aceluiași stack funcțional:**

| Componentă | Namespace actual | Schema cere |
|---|---|---|
| ECK Operator | `elastic-system` | `logging` |
| Elasticsearch | `elastic-system` | `logging` |
| Kibana | `elastic-system` | `logging` |
| **Logstash** | **`logging`** | `logging` |

Logstash e singura componentă în `logging`. Restul în `elastic-system` (default-ul Helm chart-ului ECK).

**Consecințe practice:**
1. **Logstash → ES service lookup cross-namespace** — funcționează doar pentru că ai setat explicit `elasticsearchRefs.namespace: elastic-system`. Sensibil la regresii.
2. **NetworkPolicies imposibile coerent** — dacă vrei isolation pe namespace, Logstash nu poate vorbi cu ES fără policy specifică cross-namespace.
3. **Schema arhitecturală vs realitate diferite** — vezi N2.

**Fix recomandat** (alege una):

**Opțiunea A — Aliniere cu schema (mută TOT în `logging`)**:
1. `argo-apps/infra-eck.yaml:35` → `namespace: logging`
2. `infra/elasticsearch/elasticsearch.yaml:5` + `argo-apps/infra-elasticsearch.yaml:20` → `namespace: logging`
3. `infra/kibana/kibana.yaml:5` + `infra/kibana/ingress.yaml:13` + `argo-apps/infra-kibana.yaml:20` → `namespace: logging`
4. `infra/logstash/logstash.yaml` `elasticsearchRefs.namespace` → `logging`

ArgoCD cu `prune: true` va prune resursele din `elastic-system` și recreea în `logging`. Curățenie după: `kubectl delete ns elastic-system`.

**Opțiunea B — Actualizează schema să zică `elastic-system`**:
Edit `docs/architecture.drawio` → label `ns: logging` în box-ul ECK → `ns: elastic-system`. Mai ușor, dar diluează convenția "namespace pe funcție" pe care o folosești corect pentru `auth`, `data`, `messaging`, `monitoring`.

**Recomandare**: Opțiunea A — consistență cu pattern-ul „namespace = funcție business" pe care îl ai pe restul stack-ului.

### N2 (NOU) — Schema vs implementare divergente 🟡

`docs/architecture.drawio` zice clar:
```
ns: logging
  ├─ Elasticsearch
  ├─ Kibana
  └─ Logstash
```

Implementarea actuală (vezi N1) NU respectă propria-i schemă pentru 3 din 4 componente.

**Risk pedagogic**: dacă altcineva clonează repo-ul ca template, schema îl va induce în eroare.

### N3 (NOU) — Lipsește log shipper (Filebeat sau echivalent) 🟡

**Pipeline-ul Logstash așteaptă input TCP pe portul 5044** cu `codec => json_lines`. Asta implică o singură abordare practică:

**Aplicațiile trimit log-uri direct la Logstash** prin `LogstashTcpSocketAppender` (Logback/Java) sau echivalente.

**Anti-pattern în K8s native** ([12-factor app, factor XI](https://12factor.net/logs)):
- Aplicația trebuie să **nu știe** de infrastructura de logging
- Aplicația scrie pe stdout, infrastructura colectează
- Cuplaj cod ↔ infra = greu de schimbat stack-ul logging fără modificat aplicațiile

**Lipsește componenta de "collection automată"** din pod-uri:

| Opțiune | Pros | Cons |
|---|---|---|
| **Filebeat** (Beat CR) DaemonSet | gestionat de ECK Operator, integrare nativă, k8s autodiscover cu metadata | Doar logs (nu metrici) |
| **Fluent-bit** | Lightweight, CNCF, flexibil | Manual setup ConfigMap |
| **Vector** | Rapid, Rust | Mai puține integrări native ELK |

**Recomandare**: adaugă `infra/filebeat/filebeat.yaml` (CR `Beat`, type filebeat, DaemonSet, autodiscover Kubernetes, output spre Logstash:5044 sau direct ES).

Variantă mai modernă (skip Logstash dacă nu ai nevoie de transformări complexe): **Filebeat direct la ES + Ingest Pipelines** (procesare ES-side, JSON declarative). Pipeline-ul Logstash actual face doar:
- `remove_field => ["@version", "host", "port"]`
- `add_field => { "timestamp" => "%{@timestamp}" }`

Asta poate fi acoperit 100% de un Ingest Pipeline ES nativ. **Logstash devine opțional pentru caz K8s pur**.

## 🟢 Pattern-uri excelente (continuă așa)

- ✅ **Toate fix-urile din review-ul anterior aplicate sistematic** — disciplina code-review respectată
- ✅ **`clusterName: eck` păstrat** (în ciuda recomandării mele greșite) — corect, prefix pt env vars ECK injectate
- ✅ **`.gitignore` aliniat cu pattern real** — `*-secret-raw.yaml` funcționează, plus `*.key`, `*.pem`, `.env`
- ✅ **Migrare Grafana operator → embedded** consolidată
- ✅ **CNPG cu `inheritedMetadata.annotations`** pentru Reflector pe Secret-uri operator-managed — pattern profesional
- ✅ **Cross-namespace secret cu Reflector + CNPG `inheritedMetadata`** pentru postgres-keycloak → auth
- ✅ **Convenție namespace pe funcție** (`auth`, `data`, `messaging`, `monitoring`) — bună pentru tot **exceptând** logging (vezi N1)
- ✅ **Security context riguros** pe ES + Kibana + Logstash (`runAsNonRoot`, `runAsUser: 1000`, `drop: [ALL]`, `allowPrivilegeEscalation: false`)
- ✅ **Kibana ingress** cu `backend-protocol: HTTPS` + `proxy-ssl-verify: off` + port 5601 — match cu ECK self-signed
- ✅ **Logstash pipeline custom** cu input TCP json_lines + filter mutate + output ES via env vars ECK_* — sintaxă corectă chiar dacă anti-pattern arhitectural
- ✅ **Keycloak `proxy: headers: xforwarded`** — corect pentru deployment în spatele nginx-ingress
- ✅ **`server.publicBaseUrl` pe Kibana** + `xpack.banners.placement` + `telemetry.optIn: false` — UX details corecte

## 📋 Layer status

| Layer | Stare | Note |
|---|---|---|
| Operatori | 8/8 instalate | sealed-secrets, nginx-ingress, cert-manager, eck, strimzi, cnpg, keycloak-op, reflector |
| Cluster-scoped CR | 1/1 | ClusterIssuer Let's Encrypt prod |
| CR-uri namespaced | 5/6 | elasticsearch ✅, postgres-keycloak ✅, kibana ✅, keycloak ✅, logstash ✅, kafka ❌ |
| SealedSecrets | 1/3 | grafana-admin ✅, keycloak-realm ❌, kafka SCRAM ❌ |
| Ingress | 3/4 | argocd ✅, kibana ✅, grafana ✅ (embedded), keycloak ❌(M3) |
| **Logging completeness** | **partial** | ES ✅ + Kibana ✅ + Logstash ✅, dar **lipsește shipper Filebeat/Fluent-bit (N3)** → fără el, Kibana nu primește log-uri din pod-uri automat |

## 🎯 Sinteză & priorități

| Categorie | Stare |
|---|---|
| Bug-uri critice **noi** | 0 (toate fixate) |
| Issue-uri minore rămase din 2026-06-16 | 2 (M2 sync-wave, M3 keycloak ingress) |
| Issue-uri noi descoperite | 3 (N1 namespace split, N2 schema desync, N3 lipsește shipper) |
| Self-corrections review anterior | 1 (C4 clusterName: eck — păstrat corect) |

**Quick wins (ordinea recomandată)**:

1. **M2** — Adaugă `sync-wave: "4"` în `argo-apps/infra-argocd-ingress.yaml` (1 linie, <1 min)
2. **M3** — Adaugă `infra/keycloak/ingress.yaml` (template în review-ul anterior) → `auth.icode.mywire.org` live
3. **N3** — Adaugă Filebeat DaemonSet → log-uri reale în Kibana (până atunci, Kibana e gol)
4. **N1+N2** — Mută ES + Kibana + ECK Operator în `logging` (aliniere cu schema). Atenție: pierderi de date dacă PVC-ul rămâne în `elastic-system` — verifică reclaim policy înainte (`local-path` are `Delete`).

**Decizie strategică** (cere discuție):
- Păstrezi Logstash + adaugi Filebeat (pipeline `app → stdout → Filebeat → Logstash → ES`)?
- Sau migrezi la **Filebeat direct la ES + Ingest Pipelines** (drop Logstash)? — mai simplu, sufficient pentru K8s logs, ești în plus rid de TCP listener exposed.

**Pașii recomandați după**: SealedSecret pentru Keycloak admin + KeycloakRealmImport declarativ, apoi Kafka CR cu KRaft + KafkaTopic-uri per microserviciu.
