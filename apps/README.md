# ArgoCD Bootstrap Starter

Starter **minimal** pentru a porni un cluster K3s/K8s cu GitOps prin ArgoCD.

Conține:
- App of Apps (root)
- NGINX Ingress (necesar pentru orice expunere HTTP/HTTPS)
- Sealed Secrets (pentru stocare credențiale criptate în git)
- cert-manager (pentru certificate TLS valide via Let's Encrypt)

## De ce minim?

- Pornești curat, cu o stivă mică pe care o înțelegi complet
- Înveți pattern-ul de adăugare operator pas cu pas (nu primești un stack ready-made pe care nu-l înțelegi)
- Decizi tu ce componente îți trebuie (poate nu vrei ELK, poate vrei alt tool de monitoring)

Pentru un stack complet (cu observability + Grafana Operator + ECK deja configurate), vezi `argocd-platform-starter/` — același folder părinte.

## Structură

```
argocd-bootstrap-starter/
├── bootstrap/
│   └── root.yaml                  ← App of Apps (aplicat manual din laptop la Pasul 8)
├── argo-apps/                     ← scanat de root, NU conține root.yaml
│   ├── infra-nginx-ingress.yaml
│   ├── infra-sealed-secrets.yaml
│   └── infra-cert-manager.yaml
├── infra/
│   ├── nginx-ingress/values.yaml
│   ├── sealed-secrets/values.yaml
│   └── cert-manager/values.yaml
├── apps/                          ← gol; aici adaugi Application-uri pentru aplicații
└── scripts/
    ├── install.sh                 ← rulează PE SERVER: K3s + Helm + ArgoCD + customizations
    ├── wipe.sh                    ← rulează PE SERVER: k3s-uninstall + cleanup
    ├── merge-kubeconfig.sh        ← rulează pe LAPTOP (Mac/Linux): merge ~/.kube/configs/* în ~/.kube/config
    └── merge-kubeconfig.bat       ← rulează pe LAPTOP (Windows): echivalent merge
```

**De ce root.yaml stă în `bootstrap/`, nu în `argo-apps/`?**
Root scanează folderul `argo-apps/`. Dacă root.yaml ar fi acolo, root s-ar "vedea pe sine" → diff infinit + risc ca root să se șteargă singur cu `prune: true`. Mutându-l în `bootstrap/`, scannerul nu îl mai vede.

## Flow tipic (didactic, pas cu pas)

`install.sh` instalează **doar** K3s + Helm + ArgoCD + customizations. Restul faci tu manual ca să înțelegi fiecare pas:

1. **Cloudflare** — cont + domeniu + nameservers + wildcard DNS gray cloud
2. **Server** — Linux cu IP public + SG/firewall deschis
3. **Repo GitOps** — clonezi acest starter în propriul repo, înlocuiești placeholder-ele, push
4. **SSH + `install.sh`** — K3s + ArgoCD ready
5. **Port-forward** la ArgoCD UI
6. **UI: Connect Repo** (manual, ca să înveți unde se face)
7. **kubectl pe laptop** (copy kubeconfig + merge)
8. **`kubectl apply -f bootstrap/root.yaml`** de pe laptop → App-of-Apps activează cele 3 Applications

Vezi `GETTING_STARTED.md` pentru pași detaliați.

## Workflow după bootstrap

1. **Bootstrap minimal** funcțional (4 Applications: root + 3 infra)
2. **Adaugă incremental** componente (ECK, Prometheus, Strimzi, CNPG, Keycloak, etc.) urmând pattern-ul
3. **Adaugi aplicația ta** ca al N-lea Application în `argo-apps/`

Fiecare pas e un **commit + push** → ArgoCD sync. **Niciodată** nu apply manual cu `kubectl apply` resurse care ar trebui gestionate de ArgoCD.

## Ordinea de instalare (sync-waves)

ArgoCD aplică Applications în ordinea `argocd.argoproj.io/sync-wave` (numere mai mici primele). Regula generală: **operatorii + CRD-urile înaintea CR-urilor**, **infrastructura înaintea aplicațiilor**.

### Stack minim (acest starter)

| Wave | Application | Namespace | De ce înainte |
|------|-------------|-----------|---------------|
| 0 | `sealed-secrets` | `kube-system` | Necesar pentru ca orice SealedSecret din git să fie decriptat |
| 0 | `nginx-ingress` | `ingress-nginx` | Controller-ul de Ingress; necesar pentru orice expunere HTTP |
| 0 | `cert-manager` | `cert-manager` | Instalează CRD-urile `ClusterIssuer`/`Certificate` |
| 1 | `cert-manager-issuers` | `cert-manager` | `ClusterIssuer` (CR) — depinde de CRD-urile cert-manager |

### Pe măsură ce adaugi operatori (ordine recomandată)

| Wave | Componentă | Tip | Depinde de |
|------|-----------|-----|------------|
| 0 | `reflector` | operator | — (folosit pt. SealedSecret cross-namespace) |
| 0 | `eck-operator` | operator | — |
| 0 | `strimzi` | operator | — |
| 0 | `cloudnative-pg` | operator | — |
| 0 | `keycloak-operator` | operator | — |
| 1 | `kube-prometheus-stack` | operator + CR-uri | — |
| 1 | `grafana-operator` | operator | — |
| 2 | `elasticsearch` | CR (Elasticsearch) | `eck-operator` |
| 2 | `postgres-keycloak` | CR (CNPG Cluster) | `cloudnative-pg` |
| 2 | `grafana` | CR (Grafana + dashboards) | `grafana-operator` |
| 3 | `kibana` | CR (Kibana) | `elasticsearch` ready |
| 3 | `logstash` | CR (Logstash) | `elasticsearch` ready |
| 3 | `keycloak` | CR (Keycloak) | `postgres-keycloak` ready |
| 4 | `argocd-ingress` | Ingress | nginx-ingress + cert-manager-issuers |
| 4 | `cloudflared` | Tunnel (opțional) | DNS + Ingress ready |

### Grupare pe namespace

Resursele sunt grupate logic pe namespace (vezi diagrama de arhitectură). Convenția: **un namespace = o responsabilitate**.

| Namespace | Conține | Tip resurse |
|-----------|---------|-------------|
| `kube-system` | sealed-secrets controller | Operator |
| `ingress-nginx` | NGINX Ingress Controller | Operator + Service LoadBalancer |
| `cert-manager` | cert-manager + ClusterIssuer-uri | Operator + CR cluster-scoped |
| `reflector` | Reflector controller | Operator |
| `elastic-system` | ECK operator + Elasticsearch + Kibana + Logstash | Operator + CR-uri (logging stack) |
| `monitoring` | kube-prometheus-stack + grafana-operator + Grafana CR + dashboards | Operator + CR-uri (observability) |
| `messaging` | Strimzi operator + Kafka CR-uri | Operator + CR-uri |
| `data` | CloudNativePG operator + Cluster-e Postgres | Operator + CR-uri (DB) |
| `auth` | Keycloak operator + Keycloak CR + Realm imports | Operator + CR-uri (SSO) |
| `argocd` | ArgoCD + toate Application-urile | GitOps engine |
| `car-platform` *(sau numele aplicației tale)* | Microservicii business + ConfigMaps + SealedSecrets | App-urile tale |

**De ce namespace-uri separate?**
- **Izolare RBAC** — poți da acces dev-ului doar la `car-platform`, nu la `kube-system`
- **Quota & limits** — controlezi resursele per echipă/funcție
- **Network policies** — restricționezi trafic între namespace-uri (ex: `car-platform` nu poate ajunge direct la `cert-manager`)
- **Curățare ușoară** — `kubectl delete ns messaging` șterge tot Kafka-ul cu un comand
- **Lizibilitate** — în UI ArgoCD/Kibana/Grafana știi imediat ce face fiecare resursă

**Convenție denumire namespace**: nume generice pe funcție (`logging`, `messaging`, `auth`, `data`) — NU pe tehnologie (`elasticsearch`, `kafka`, `keycloak`, `postgres`). Așa, dacă mâine schimbi Kafka cu RabbitMQ, namespace-ul `messaging` rămâne valid.

### Reguli simple pentru sync-wave

- **Operator** → wave `0` (instalează CRD-urile)
- **CR care depinde direct de un CRD** → wave `1` sau `2`
- **CR care depinde de alt CR ready** (ex: Kibana → Elasticsearch ready) → wave `3`
- **Ingress + DNS + tunnel** → wave `4` (după ce serviciile sunt up)
- **App-ul tău business** → wave `5+`

Fără sync-wave (default `0`), Applications se aplică în paralel — funcționează dar la primul bootstrap pot exista retry-uri până CRD-urile sunt prezente.

## Placeholder-e de înlocuit

În `bootstrap/root.yaml` și toate `argo-apps/*.yaml`:

- `__GITHUB_USERNAME__` → username-ul tău GitHub
- `__GITHUB_REPO__` → numele repo-ului GitOps
- `targetRevision: main` → `main` sau `master` (verifică branch-ul tău)

One-liner Mac/Linux pentru toate dintr-o dată:
```bash
find argo-apps bootstrap -name "*.yaml" -exec sed -i '' \
  -e "s|__GITHUB_USERNAME__|<owner>|g" \
  -e "s|__GITHUB_REPO__|<repo>|g" {} \;
```

(pe Linux scoate `''` după `-i`).
