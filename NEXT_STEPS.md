# Next Steps — după MIGRATION_GRAFANA

Roadmap prioritizat pentru completarea stack-ului. Fiecare prioritate e independentă — poți sări pasă-le în ordine logică sau în funcție de ce vrei mai întâi.

```
P1 — Filebeat               ⚡ închide ELK end-to-end (Kibana vede logs)
P2 — Kafka CR + UI          📦 activează Strimzi
P3 — Keycloak CR + Realm    🔐 layer auth complet
P4 — Ingress per serviciu   🌐 acces UI public (argocd, prometheus, etc.)
P5 — Cleanup + securitate   🧹 docs sync, parola plain, .gitignore strict
P6 — Layer business         🏗️ Kong + microservicii + Istio + Tempo
```

---

## P1 — Filebeat (închide pipeline logging)

**De ce primul**: ai ECK + Elasticsearch + Kibana — dar **fără Filebeat Kibana e gol**. Filebeat colectează logs din `/var/log/containers/` și le trimite la Elasticsearch automat. Kibana 8.x include dashboard-uri "K8s logs" care apar singure odată ce există date.

### 1.1 Fișier Application

`argo-apps/infra-filebeat.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: filebeat
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "3"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/nimigeanconstantinion/ms-gitops.git
    targetRevision: master
    path: infra/filebeat
  destination:
    server: https://kubernetes.default.svc
    namespace: elastic-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

### 1.2 Filebeat CR (DaemonSet — pe fiecare nod)

`infra/filebeat/filebeat.yaml`:

```yaml
apiVersion: beat.k8s.elastic.co/v1beta1
kind: Beat
metadata:
  name: filebeat
  namespace: elastic-system
spec:
  type: filebeat
  version: 8.15.3   # match cu Elasticsearch

  elasticsearchRef:
    name: elasticsearch
  kibanaRef:
    name: kibana   # auto-setup dashboards "K8s logs" în Kibana

  config:
    filebeat.autodiscover:
      providers:
        - type: kubernetes
          node: ${NODE_NAME}
          hints.enabled: true
          hints.default_config:
            type: container
            paths:
              - /var/log/containers/*${data.kubernetes.container.id}.log
    processors:
      - add_cloud_metadata: {}
      - add_host_metadata: {}

  daemonSet:
    podTemplate:
      spec:
        serviceAccountName: filebeat
        automountServiceAccountToken: true
        terminationGracePeriodSeconds: 30
        dnsPolicy: ClusterFirstWithHostNet
        hostNetwork: true
        containers:
          - name: filebeat
            securityContext:
              runAsUser: 0   # necesar pentru a citi /var/log/
            volumeMounts:
              - name: varlogcontainers
                mountPath: /var/log/containers
              - name: varlogpods
                mountPath: /var/log/pods
              - name: varlibdockercontainers
                mountPath: /var/lib/docker/containers
            env:
              - name: NODE_NAME
                valueFrom:
                  fieldRef:
                    fieldPath: spec.nodeName
            resources:
              requests:
                cpu: 100m
                memory: 100Mi
              limits:
                cpu: 500m
                memory: 200Mi
        volumes:
          - name: varlogcontainers
            hostPath:
              path: /var/log/containers
          - name: varlogpods
            hostPath:
              path: /var/log/pods
          - name: varlibdockercontainers
            hostPath:
              path: /var/lib/docker/containers
```

### 1.3 RBAC pentru Filebeat (autodiscover Kubernetes)

`infra/filebeat/rbac.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: filebeat
  namespace: elastic-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: filebeat
rules:
  - apiGroups: [""]
    resources: ["namespaces", "pods", "nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["replicasets"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: filebeat
subjects:
  - kind: ServiceAccount
    name: filebeat
    namespace: elastic-system
roleRef:
  kind: ClusterRole
  name: filebeat
  apiGroup: rbac.authorization.k8s.io
```

### 1.4 Commit + verify

```bash
git add argo-apps/infra-filebeat.yaml infra/filebeat/
git commit -m "feat: add filebeat DaemonSet for log shipping"
git push

# Verify
kubectl -n elastic-system get beat
kubectl -n elastic-system get ds filebeat-beat-filebeat
kubectl -n elastic-system get pods -l beat.k8s.elastic.co/name=filebeat
# 1 pod per nod, Status: Running

# Verify logs ajung la Elasticsearch
kubectl -n elastic-system exec -it elasticsearch-es-default-0 -- \
  curl -k -u elastic:<pass> https://localhost:9200/_cat/indices?v | grep filebeat
# așteptat: index "filebeat-8.15.3-<data>" cu docs.count > 0
```

În Kibana → **Discover** → selectează data view `filebeat-*` → vezi logs din toate pod-urile.

---

## P2 — Kafka CR + UI

Strimzi instalat e doar operator. Necesar `Kafka` + `KafkaNodePool` pentru a avea broker.

### 2.1 Application

`argo-apps/infra-kafka.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kafka
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/nimigeanconstantinion/ms-gitops.git
    targetRevision: master
    path: infra/kafka
  destination:
    server: https://kubernetes.default.svc
    namespace: messaging
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

### 2.2 KafkaNodePool (KRaft mode, fără ZooKeeper)

`infra/kafka/kafka-nodepool.yaml`:

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: dual-role
  namespace: messaging
  labels:
    strimzi.io/cluster: kafka
spec:
  replicas: 1
  roles: [controller, broker]
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: 10Gi
        class: local-path
        deleteClaim: false
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: 1
      memory: 1Gi
```

### 2.3 Kafka cluster CR

`infra/kafka/kafka-cluster.yaml`:

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: kafka
  namespace: messaging
  annotations:
    strimzi.io/node-pools: enabled
    strimzi.io/kraft: enabled
spec:
  kafka:
    version: 3.8.0
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: tls
        port: 9093
        type: internal
        tls: true
    config:
      offsets.topic.replication.factor: 1
      transaction.state.log.replication.factor: 1
      transaction.state.log.min.isr: 1
      default.replication.factor: 1
      min.insync.replicas: 1
      inter.broker.protocol.version: "3.8"
  entityOperator:
    topicOperator: {}
    userOperator: {}
```

### 2.4 KafkaTopic-uri inițiale

`infra/kafka/topics/orders-events.yaml`:

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: orders-events
  namespace: messaging
  labels:
    strimzi.io/cluster: kafka
spec:
  partitions: 3
  replicas: 1
  config:
    retention.ms: 604800000   # 7 zile
    segment.bytes: 1073741824
```

Adaugă `inventory-events.yaml`, `audit-events.yaml`, etc. în același folder după nevoie.

### 2.5 Kafka UI (opțional, foarte util)

`argo-apps/infra-kafka-ui.yaml` cu chart `provectus/kafka-ui` (clasic Helm) — UI pentru topic-uri/consumer groups/messages. Adaugă wave 3 + Ingress `kafka-ui.icode.mywire.org`.

### 2.6 Verify

```bash
kubectl -n messaging get kafka kafka -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# așteptat: True

kubectl -n messaging get pods
# kafka-dual-role-0 (broker), kafka-entity-operator-... (topic + user op)

kubectl -n messaging get kafkatopic
# orders-events, ... cu STATUS=True
```

---

## P3 — Keycloak CR + RealmImport

Layer auth — necesită lanț: Postgres ready → SealedSecret DB → Reflector mirror → Keycloak CR → Realm.

### 3.1 SealedSecret pentru Postgres credentials

```bash
cat > /tmp/pg-keycloak-raw.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: postgres-keycloak-credentials
  namespace: data
  annotations:
    # Reflector va replica în ns: auth pentru Keycloak
    reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
    reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "auth"
    reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
    reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "auth"
type: kubernetes.io/basic-auth
stringData:
  username: keycloak
  password: "ParolaSiguraKeycloak!"
EOF

kubeseal --controller-namespace kube-system \
         --controller-name sealed-secrets-controller \
         --format yaml \
         < /tmp/pg-keycloak-raw.yaml \
         > infra/postgres-keycloak/credentials-sealed.yaml

rm /tmp/pg-keycloak-raw.yaml
```

> ⚠️ Anotările Reflector **trebuie sigilate înăuntrul** SealedSecret (în secțiunea `template.metadata.annotations`), nu pe SealedSecret însăși. Vezi `infra/grafana/secrets/grafana-sealed.yaml` pentru pattern.

### 3.2 Verifică Postgres-keycloak Cluster e Ready

```bash
kubectl -n data get cluster postgres-keycloak
# STATUS: Cluster in healthy state

kubectl -n auth get secret postgres-keycloak-credentials
# trebuie să existe (replicat de Reflector)
```

### 3.3 Keycloak CR

`argo-apps/infra-keycloak.yaml` wave 3 + `infra/keycloak/keycloak.yaml`:

```yaml
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: keycloak
  namespace: auth
spec:
  instances: 1
  db:
    vendor: postgres
    host: postgres-keycloak-rw.data.svc.cluster.local
    port: 5432
    database: keycloak
    usernameSecret:
      name: postgres-keycloak-credentials
      key: username
    passwordSecret:
      name: postgres-keycloak-credentials
      key: password
  hostname:
    hostname: auth.icode.mywire.org
  http:
    tlsSecret: keycloak-tls
  ingress:
    enabled: false   # ingress separat cu cert-manager
```

### 3.4 KeycloakRealmImport (realm pre-configurat)

`infra/keycloak/realm-import.yaml`:

```yaml
apiVersion: k8s.keycloak.org/v2alpha1
kind: KeycloakRealmImport
metadata:
  name: car-platform-realm
  namespace: auth
spec:
  keycloakCRName: keycloak
  realm:
    realm: car-platform
    enabled: true
    clients:
      - clientId: car-platform-ui
        publicClient: true
        redirectUris:
          - "https://app.icode.mywire.org/*"
        webOrigins: ["+"]
    roles:
      realm:
        - name: admin
        - name: user
```

### 3.5 Ingress

`infra/keycloak/ingress.yaml` (similar cu Kibana, fără backend HTTPS):

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
      secretName: keycloak-tls
  rules:
    - host: auth.icode.mywire.org
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: keycloak-service
                port: { number: 8080 }
```

### 3.6 Verify

```bash
kubectl -n auth get keycloak
# STATUS: Ready

kubectl -n auth get keycloakrealmimport
# DONE: True

# Login UI: https://auth.icode.mywire.org
# Username default: admin (parola pe care ai sealed-uit-o)
```

---

## P4 — Ingress per serviciu

Acum doar Grafana + Kibana au Ingress public. Adaugă pentru UI-urile rămase.

### 4.1 ArgoCD Ingress

`argo-apps/infra-argocd-ingress.yaml` wave 4:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd-ingress
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "4"
spec:
  project: default
  source:
    repoURL: https://github.com/nimigeanconstantinion/ms-gitops.git
    targetRevision: master
    path: infra/argocd-ingress
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

`infra/argocd-ingress/ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd
  namespace: argocd
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/backend-protocol: "GRPC"   # ArgoCD CLI face gRPC
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts: [argocd.icode.mywire.org]
      secretName: argocd-tls
  rules:
    - host: argocd.icode.mywire.org
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port: { number: 80 }
```

> Notă: backend-protocol GRPC vs HTTPS depinde de cum e configurat argocd-server. Cu `server.insecure=true` (din install.sh) → HTTP simplu, scoate `backend-protocol`.

### 4.2 Prometheus + Alertmanager (cu BasicAuth)

Sunt SENSITIVE (toate metricile interne). Protejează cu BasicAuth:

```bash
# Generează BasicAuth secret
htpasswd -c -b auth admin "ParolaPrometheus!"
kubectl -n monitoring create secret generic basic-auth-prometheus --from-file=auth

# Sigilează-l!
kubectl -n monitoring get secret basic-auth-prometheus -o yaml \
  | grep -v "^\s*creationTimestamp\|^\s*resourceVersion\|^\s*uid" \
  > /tmp/basic-auth-raw.yaml
kubeseal < /tmp/basic-auth-raw.yaml > infra/monitoring/basic-auth-sealed.yaml
rm /tmp/basic-auth-raw.yaml auth
```

`infra/monitoring/ingress-prometheus.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prometheus
  namespace: monitoring
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: basic-auth-prometheus
    nginx.ingress.kubernetes.io/auth-realm: "Auth Required"
spec:
  ingressClassName: nginx
  tls:
    - hosts: [prometheus.icode.mywire.org]
      secretName: prometheus-tls
  rules:
    - host: prometheus.icode.mywire.org
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kube-prometheus-stack-prometheus
                port: { number: 9090 }
```

Similar `ingress-alertmanager.yaml` + `ingress-kafka-ui.yaml` (după P2).

---

## P5 — Cleanup + securitate

### 5.1 M2: bootstrap/root.yaml comentariu

`bootstrap/root.yaml:14`:
```yaml
# Înainte
targetRevision: master   # SAU master — ajustează după branch-ul real al repo-ului

# După
targetRevision: master
```

### 5.2 M3: regenerează README + GETTING_STARTED

README declară 4 Apps — realitate 14+. Opțiuni:
- **A**: șterge tabelul cu "Conține DOAR" și înlocuiește cu trimitere la `argo-apps/README.md`
- **B**: regenerează tot README cu state-ul curent + lista 14 Applications

### 5.3 .gitignore strict

`.gitignore` actual prinde doar `*-secret-raw.yaml`. Adaugă:

```gitignore
# Refuză toate Secret-urile plain în secrets/
**/secrets/*-secret.yaml
**/secrets/*-raw.yaml
**/secrets/*-credentials.yaml
# Lasă să treacă explicit doar sealed
!**/secrets/*-sealed.yaml
```

### 5.4 Rotire parolă plain Grafana (repo PUBLIC)

`commit 8766144` conține `StrongPassword123` plain. Repo `nimigeanconstantinion/ms-gitops` e **public**. Opțiuni:

| Strategie | Acțiune | Risk |
|---|---|---|
| **Soft** (recomandat) | Rotește parola activă la una nouă sigilată. Comentariu în README "commit X conține credential revocat" | Parola veche rămâne în istoria publică, dar e inutilă |
| **Hard** | `git filter-repo --invert-paths --path infra/grafana/secrets/grafana-secret.yaml` + force push | Rescrie istoria; periculos dacă altcineva a clonat (rar la repo de lab) |

### 5.5 SealedSecret-uri lipsă

Audit final — orice `Secret` plain rămas în git:

```bash
grep -rn "kind: Secret$" infra/ argo-apps/
# Așteptat: doar SealedSecret-uri, niciun Secret plain
```

---

## P6 — Layer business (sesiune separată)

Stack-ul de aplicații (`ns: car-platform` din diagrama target) — complexitate mare, depinde de ce vrea Constantin să deployeze efectiv.

### Componente target

| Componentă | Rol | Wave |
|---|---|---|
| Istio (istiod + Kiali) | Service mesh — mTLS, telemetry, routing | 0/1 |
| Tempo | Distributed tracing (OTLP collector) | 1 |
| Kong Runtime | Gateway intern (NU ingressController) | 5 |
| importer-service | Microserviciu (Spring? Node?) | 5 |
| sync-service | Microserviciu | 5 |
| ui (React) | Front-end | 5 |
| mock-source (C#) | Test data generator | 5 |

### Considerații

- **Istio injection per namespace** (`istio-injection=enabled` label) — pod-urile primesc Envoy sidecar
- **PeerAuthentication STRICT** (mTLS între servicii) + NetworkPolicies default-deny
- **Telemetry → OTLP → Tempo** pentru tracing distribuit
- Kong pentru rate limiting + auth integration cu Keycloak

→ Sesiune separată cu Constantin după ce ai claritate pe stack-ul de aplicații.

---

## Checklist global după P1-P5

- [ ] **P1** Filebeat DaemonSet pe toate nodurile; logs ajung în Elasticsearch
- [ ] **P1** Kibana Discover arată logs filtrabile pe namespace/pod/app
- [ ] **P2** Kafka cluster Ready cu 1 broker KRaft
- [ ] **P2** KafkaTopic-uri inițiale create
- [ ] **P3** SealedSecret postgres-keycloak în ns:data + replicat în ns:auth via Reflector
- [ ] **P3** Keycloak CR Ready, login UI la `https://auth.icode.mywire.org`
- [ ] **P3** Realm `car-platform` importat cu clients/roles
- [ ] **P4** Ingress `argocd.icode.mywire.org` (UI public cu cert valid)
- [ ] **P4** Ingress `prometheus/alertmanager.icode.mywire.org` cu BasicAuth
- [ ] **P5** README + GETTING_STARTED sync cu state-ul curent
- [ ] **P5** `.gitignore` strict pentru secrets
- [ ] **P5** Parola plain Grafana din commit 8766144 rotită
- [ ] **P5** Niciun `kind: Secret` plain în repo (audit)

## Pattern de aplicare

Pentru fiecare P:
1. Citește secțiunea P*N* din acest fișier
2. Creează fișierele YAML noi
3. Commit + push (un commit per P)
4. ArgoCD detectează automat — verifică în UI sau cu `kubectl -n argocd get app`
5. Verifică în cluster cu comenzile din secțiunea "Verify"
6. Bifează checklist

## Rollback per P

Fiecare P e un Application separat — rollback simplu:

```bash
# Șterge Application (declanșează prune)
kubectl -n argocd delete app <nume-p>

# Sau git revert
git revert HEAD
git push
```

## Status urmărire

Pe măsură ce avansezi, actualizează tabelul de mai jos:

| P | Status | Dată | Note |
|---|---|---|---|
| P1 Filebeat | ☐ TODO | | |
| P2 Kafka | ☐ TODO | | |
| P3 Keycloak | ☐ TODO | | |
| P4 Ingress | ☐ TODO | | |
| P5 Cleanup | ☐ TODO | | |
| P6 Business | ☐ Pending | | sesiune separată |
