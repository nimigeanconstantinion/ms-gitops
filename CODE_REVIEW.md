# Code Review — ctin-gitops (2026-06-16)

Stare: **14 Applications** (au apărut postgres-keycloak, keycloak CR, kibana CR, elasticsearch CR, logstash CR, argocd-ingress; au plecat grafana-operator + grafana CR-uri custom — migrare la Grafana embedded în kube-prometheus-stack realizată). Bootstrap-ul e curat, dar **stack-ul nou are 4 bug-uri critice și o scurgere de credențiale în repo public**.

## 🔴 Bug-uri critice — fix înainte de orice push nou

### C1 — Parolă plain text în repo PUBLIC

**Unde**: `infra/kube-prometheus-stack/grafana-admin-raw.yaml:9`

```yaml
stringData:
  admin-user: admin
  admin-password: "StrongPassword123"
```

Fișierul e **tracked în git** și repo-ul `nimigeanconstantinion/ms-gitops` e public. Parola e indexată pe GitHub, vizibilă oricui, și rămâne în istoric chiar dacă o ștergi acum.

**Cauză colaterală**: pattern-ul `.gitignore` `*-secret-raw.yaml` nu matchează `grafana-admin-raw.yaml` (lipsește `secret` din nume).

**Fix imediat**:
```bash
# 1. Schimbă parola Grafana — orice e în istoric e compromis
# 2. Re-sigilează cu noua parolă (kubeseal)
# 3. Șterge raw-ul din repo + istoric
git rm infra/kube-prometheus-stack/grafana-admin-raw.yaml
git filter-repo --invert-paths --path infra/kube-prometheus-stack/grafana-admin-raw.yaml
git push --force origin master   # ATENȚIE — rescrie istoric
```

**Prevenție**: alinează `.gitignore` cu numele real folosit:
```
# Local secrets (NU commit niciodată!)
*-raw.yaml          # mai larg decât *-secret-raw.yaml
*.key
*.pem
.env
.env.local
```

### C2 — Ingress ArgoCD nu funcționează (HTTPS vs HTTP + service inexistent)

**Unde**: `infra/argocd-ingress/ingress.yaml`

Două probleme în același fișier:

**Problema A — protocol mismatch**: `bootstrap/install.sh:47` pornește argocd-server cu `--set configs.params."server\.insecure"=true` → server-ul ascultă HTTP plain. Ingress-ul însă cere:

```yaml
nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
nginx.ingress.kubernetes.io/proxy-ssl-verify: "off"
port:
  number: 443
```

nginx face TLS handshake către un server HTTP → **502 Bad Gateway**.

**Problema B — nume serviciu greșit**: ingress referă `name: argo-cd-argocd-server`. Chart-ul `argo-helm/argo-cd` are `nameOverride` default `"argocd"` (nu `Chart.Name`). Cu release `argocd` → fullname = `argocd` → service = **`argocd-server`** (confirmat de `install.sh:49` care urmărește `deployment argocd-server`).

**Fix**:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts: [argocd.icode.mywire.org]
      secretName: argocd-tls-cert
  rules:
    - host: argocd.icode.mywire.org
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server   # nu argo-cd-argocd-server
                port:
                  number: 80          # nu 443 — server e --insecure
```

**Verificare**:
```bash
kubectl -n argocd get svc | grep server
# argocd-server   ClusterIP   ...   80/TCP,443/TCP

kubectl -n argocd get cm argocd-cmd-params-cm -o yaml | grep insecure
# server.insecure: "true"

curl -I https://argocd.icode.mywire.org/      # după sync
```

### C3 — Conflict Secret + SealedSecret pe `grafana-admin-credentials`

**Unde**: `infra/kube-prometheus-stack/grafana-admin-raw.yaml` și `infra/kube-prometheus-stack/sealed-secrets/grafana-admin-sealed.yaml`

Ambele fișiere creează un Secret cu același nume `grafana-admin-credentials` în namespace `monitoring`. ArgoCD aplică ambele:
- Secret-ul raw scrie direct cheile
- SealedSecret e decriptat de controller și suprascrie

Rezultat: **drift permanent OutOfSync + race condition** între ArgoCD reconcile și sealed-secrets controller. Fix-ul C1 (ștergere raw) rezolvă și acest bug.

### C4 — Logstash trimite la Elasticsearch în namespace inexistent

**Unde**: `infra/logstash/logstash.yaml:11-14`

```yaml
elasticsearchRefs:
  - clusterName: eck
    name: elasticsearch
    namespace: logging     # ← greșit
```

Dar `Elasticsearch` rulează în `elastic-system` (vezi `infra/elasticsearch/elasticsearch.yaml:5` + `argo-apps/infra-elasticsearch.yaml:20`). Logstash va rămâne în `Pending`/`CrashLoopBackOff` cu eroare „Elasticsearch resource not found".

**Plus**: câmpul `clusterName: eck` e pentru `RemoteCluster` setup (multi-cluster ES), nu pentru ref local — scoate-l.

**Fix**:
```yaml
elasticsearchRefs:
  - name: elasticsearch
    namespace: elastic-system
```

**Decizie colaterală** — `argo-apps/infra-logstash.yaml:20` îl pune în namespace `logging`, dar `apps/README.md:110` zice convenția: ELK stă în `elastic-system`. Două opțiuni:
- (a) Mută Logstash în `elastic-system` (consistent cu convenția documentată)
- (b) Lasă-l în `logging` ca namespace dedicat ingestion, dar atunci actualizează tabelul din `apps/README.md`

## 🟡 Issue-uri minore

### M1 — `argo-apps/README.md` desincronizat

Tabelul listează 12 Applications, lipsesc: `argocd-ingress`, `kibana`, `keycloak`, `logstash`, `postgres-keycloak`. Apar încă `grafana-operator` și `grafana` deși au fost șterse în migrarea Grafana embedded. Mențiunea „Grafana dezactivat" e falsă acum (e activă embedded în kube-prometheus-stack).

Regenerează tabelul din `ls argo-apps/infra-*.yaml`.

### M2 — `argocd-ingress` fără sync-wave

`argo-apps/infra-argocd-ingress.yaml` nu are anotare. Per regulile din `apps/README.md:97`, Ingress-urile sunt wave `4`. Pentru consistență:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "4"
```

### M3 — Keycloak fără Ingress

`infra/keycloak/keycloak.yaml:22-24` declară `hostname: https://auth.icode.mywire.org` cu `strict: true`. Fără Ingress rutat la service-ul Keycloak, hostname-ul nu rezolvă din afară → utilizatorul vede ERR_CONNECTION_REFUSED, iar cu `strict: true` Keycloak refuză request-uri pe alt hostname.

Adaugă `infra/keycloak/ingress.yaml` (urmează pattern-ul Kibana — backend HTTP plain, cert-manager pentru TLS):

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: keycloak
  namespace: auth
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts: [auth.icode.mywire.org]
      secretName: keycloak-tls-cert
  rules:
    - host: auth.icode.mywire.org
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: keycloak-service     # verifică: kubectl -n auth get svc
                port:
                  number: 8080
```

### M4 — `GETTING_STARTED.md` referă fișiere ce nu există

Pasul 7 din `GETTING_STARTED.md` prezintă ClusterIssuer ca „creează manual" — dar e deja în repo (`infra/cert-manager-issuers/clusterissuer.yaml`). Probabil rămas din starter.

## 🟢 Pattern-uri corecte (continuă așa)

- ✅ **Migrare Grafana operator → embedded** — clean: 5 fișiere șterse, values consolidat, datasource auto-detect, ~20 dashboards default
- ✅ **Cross-namespace secret cu Reflector + CNPG `inheritedMetadata`** — `postgres-keycloak` propagă annotations Reflector pe Secret-ul `*-app` generat, mirror în `auth` automat. Pattern profesional.
- ✅ **Convenție namespace pe funcție** (`auth`, `data`, `messaging`, `monitoring`) — nu pe tehnologie
- ✅ **Security context riguros** pe Elasticsearch + Kibana + Logstash (`runAsNonRoot`, `drop: [ALL]`, `selfSignedCertificate`)
- ✅ **Kibana ingress corect configurat** (`backend-protocol: HTTPS` + `proxy-ssl-verify: off` + port 5601) — match cu ECK self-signed
- ✅ **Logstash pipeline custom** cu input TCP json_lines + filter mutate + output ES via env vars ECK_*  (ECK injectează automat credentials + CA)
- ✅ **CNPG cu `inheritedMetadata.annotations`** — soluție corectă pentru Reflector pe Secret-uri gestionate de operator (nu poți edita direct Secret-ul)
- ✅ **Keycloak `proxy: headers: xforwarded`** — corect pentru deployment în spatele nginx-ingress

## 📋 Layer status

| Layer | Stare | Note |
|---|---|---|
| Operatori | 8/8 instalate | sealed-secrets, nginx-ingress, cert-manager, eck, strimzi, cnpg, keycloak-op, reflector |
| Cluster-scoped CR | 1/1 | ClusterIssuer Let's Encrypt prod |
| CR-uri namespaced | 5/6 | elasticsearch ✅, postgres-keycloak ✅, kibana ✅, keycloak ✅, logstash 🔴(C4), kafka ❌ |
| SealedSecrets | 1/3 | grafana-admin ✅ (cu C1+C3), keycloak-realm ❌, kafka SCRAM ❌ |
| Ingress | 2/4 | argocd 🔴(C2), kibana ✅, grafana ✅ (via chart), keycloak ❌(M3) |

## 🎯 Sinteză & priorități

| Categorie | Stare |
|---|---|
| Bug-uri critice | 4 (C1 securitate, C2 ingress argocd, C3 conflict secret, C4 logstash namespace) |
| Issue-uri minore | 4 (README desync, sync-wave, ingress keycloak, GS stale) |
| Documentație sync | ~40% (CODE_REVIEW e cel actualizat; argo-apps/README + apps/README în urmă) |

**Risk #1**: parola Grafana e expusă public în git history → orice e indexat pe GitHub e considerat compromis. **Schimbă parola înainte de orice altă acțiune**.

**Quick wins (ordine logică)**:

1. **C1** — rotează parola Grafana + șterge raw + `filter-repo` (~15 min)
2. **C2** — fix ingress ArgoCD (1 fișier, 3 linii) → UI accesibil
3. **C4** — fix namespace Logstash (1 linie) → ELK end-to-end funcțional
4. **M3** — adaugă ingress Keycloak → `auth.icode.mywire.org` live

După alea: SealedSecret pentru Keycloak admin + KeycloakRealmImport, apoi Kafka CR cu KRaft.
