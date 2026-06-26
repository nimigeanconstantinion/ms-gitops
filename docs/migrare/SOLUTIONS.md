# Soluții concrete — CI/CD + migrare microservicii

> Detaliază **CUM** implementăm fiecare item din [`BACKLOG.md`](BACKLOG.md). Snippet-uri copy-paste, adaptabile.
> Servicii: `importer-service` (Java :8082), `data-service` (Java :8081), `client/UI` (Vite :3000). Imagini: `ion21/*`.

---

## 1. Pipeline CI/CD complet (reusable workflow)

**Problema:** azi `deploy.yml` = doar build+push, zero teste, tag dată, fără CD.
**Soluția:** un workflow reutilizabil cu 4 etape. Întâi versiunea per-serviciu (Java); apoi cum îl faci reusable.

### 1.1 Workflow Java (`data-service` / `importer-service`)
`.github/workflows/ci.yml`:
```yaml
name: CI/CD
on:
  push: { branches: [ master ] }
  pull_request: { branches: [ master ] }
  workflow_dispatch:

env:
  IMAGE: ion21/data-service        # schimbă per serviciu

jobs:
  build-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with: { distribution: temurin, java-version: '17', cache: maven }
      - name: Build + unit + integration (Testcontainers)
        run: ./mvnw -B verify          # eșuează => oprește pipeline-ul

  scan:
    needs: build-test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Trivy (filesystem)
        uses: aquasecurity/trivy-action@master
        with: { scan-type: fs, severity: 'CRITICAL,HIGH', exit-code: '1', ignore-unfixed: true }

  publish:
    needs: [build-test, scan]
    if: github.ref == 'refs/heads/master'
    runs-on: ubuntu-latest
    outputs: { tag: ${{ steps.meta.outputs.sha7 }} }
    steps:
      - uses: actions/checkout@v4
      - id: meta
        run: echo "sha7=${GITHUB_SHA::7}" >> "$GITHUB_OUTPUT"
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with: { username: ${{ secrets.DOCKERHUB_USERNAME }}, password: ${{ secrets.DOCKERHUB_TOKEN }} }
      - uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/amd64,linux/arm64
          push: true
          tags: |
            ${{ env.IMAGE }}:${{ steps.meta.outputs.sha7 }}
            ${{ env.IMAGE }}:latest

  cd-bump:                            # închide bucla CI -> CD
    needs: publish
    if: github.ref == 'refs/heads/master'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          repository: nimigeanconstantinion/ms-gitops
          token: ${{ secrets.GITOPS_PAT }}      # PAT least-privilege (vezi §6)
      - name: Bump image tag în gitops
        run: |
          sed -i -E "s|(ion21/data-service:)[a-zA-Z0-9._-]+|\1${{ needs.publish.outputs.tag }}|" \
            business/data-service.yaml
          git config user.name  "ci-bot"
          git config user.email "ci-bot@users.noreply.github.com"
          git commit -am "ci: data-service -> ${{ needs.publish.outputs.tag }}"
          git push
```
→ ArgoCD (auto-sync) vede commit-ul și deployează. **Push în cod = deploy în cluster.**

### 1.2 Reusable (DRY) — un singur workflow pentru toate
Într-un repo central `.github/workflows/reusable-java-ci.yml` cu `on: workflow_call` + `inputs: { image, java_version }`. Fiecare serviciu îl apelează:
```yaml
jobs:
  ci:
    uses: nimigeanconstantinion/ci-shared/.github/workflows/reusable-java-ci.yml@main
    with: { image: ion21/data-service }
    secrets: inherit
```

---

## 2. Testare locală — docker-compose (dependențe reale)

**Soluția:** un compose care pornește exact infra de care depind serviciile, cu realm `rsk` pre-importat.

`docker-compose.yaml`:
```yaml
services:
  mysql:
    image: mysql:8.0
    environment: { MYSQL_ROOT_PASSWORD: root, MYSQL_DATABASE: micro_db }
    ports: ["3306:3306"]

  kafka:                              # Redpanda = Kafka API, pornire rapidă, fără ZK
    image: redpandadata/redpanda:latest
    command: redpanda start --smp 1 --overprovisioned --node-id 0 --check=false
             --kafka-addr PLAINTEXT://0.0.0.0:9092 --advertise-kafka-addr PLAINTEXT://localhost:9092
    ports: ["9092:9092"]

  keycloak:
    image: quay.io/keycloak/keycloak:26.1
    command: start-dev --import-realm
    environment: { KEYCLOAK_ADMIN: admin, KEYCLOAK_ADMIN_PASSWORD: admin }
    volumes: ["./keycloack/realm-export.json:/opt/keycloak/data/import/realm.json:ro"]
    ports: ["8085:8080"]
```
Rulezi serviciul peste ele:
```bash
docker compose up -d
./mvnw spring-boot:run -Dspring-boot.run.profiles=local
# smoke: http://localhost:8081/swagger-ui.html
```
> `realm-export.json` cu realm `rsk` + client `register-user` îl ai deja în `keycloack/` din chart-ul lui.

---

## 3. Integration tests cu Testcontainers (rulează și în CI)

**Soluția:** testezi lanțul real (Kafka→consumer→MySQL) cu containere efemere, fără infra externă.

`pom.xml`:
```xml
<dependency><groupId>org.testcontainers</groupId><artifactId>kafka</artifactId><scope>test</scope></dependency>
<dependency><groupId>org.testcontainers</groupId><artifactId>mysql</artifactId><scope>test</scope></dependency>
<dependency><groupId>org.testcontainers</groupId><artifactId>junit-jupiter</artifactId><scope>test</scope></dependency>
```
`DataServiceIT.java`:
```java
@SpringBootTest
@Testcontainers
class DataServiceIT {
  @Container static KafkaContainer kafka =
      new KafkaContainer(DockerImageName.parse("confluentinc/cp-kafka:7.6.1"));
  @Container static MySQLContainer<?> mysql =
      new MySQLContainer<>("mysql:8.0").withDatabaseName("micro_db");

  @DynamicPropertySource
  static void props(DynamicPropertyRegistry r) {
    r.add("spring.kafka.bootstrap-servers", kafka::getBootstrapServers);
    r.add("spring.datasource.url",      mysql::getJdbcUrl);
    r.add("spring.datasource.username", mysql::getUsername);
    r.add("spring.datasource.password", mysql::getPassword);
  }

  @Test void consuma_eveniment_si_salveaza_in_db() {
    // produce un MessageEvent pe product-topic -> asteapta -> assert ca produsul e in repo
  }
}
```
`./mvnw verify` îl rulează automat (Surefire/Failsafe) — **același test în CI**.

---

## 4. Fix importer — din hardcodat în env-driven

**Problema:** `application-helm.yaml` are valori fixe + parolă plain.
**Soluția:** parametrizezi totul cu `${ENV:default}` (ca data-service).

**Înainte (rău):**
```yaml
datasource:
  url: jdbc:mysql://78.96.25.131:3306/test_db
  password: R@0t
Kafka:
  bootstrap-servers: localhost:30001
```
**După (bun):**
```yaml
datasource:
  url: ${MYSQL_URL:jdbc:mysql://localhost:3306/micro_db}
  username: ${MYSQL_USERNAME:root}
  password: ${MYSQL_PASSWORD:root}
spring:
  kafka:
    bootstrap-servers: ${KAFKA_BOOTSTRAP_SERVERS:localhost:9092}
  security:
    oauth2:
      resourceserver:
        jwt:
          jwk-set-uri: ${KEYCLOAK_JWK_SET_URI}
```
Apoi parola reală vine din Secret (K8s), nu din cod. **Rotește `R@0t`** (a fost în git public).

---

## 5. UI — runtime config (fără rebuild per mediu)

**Problema:** Vite injectează `VITE_*` la **build-time** → o imagine = un singur mediu.
**Soluția:** config citit la **runtime** dintr-un fișier servit de nginx, suprascris în cluster cu ConfigMap.

`public/app-config.json` (default dev):
```json
{ "API_URL": "http://localhost:5000", "KEYCLOAK_URL": "http://localhost:8085", "REALM": "rsk", "CLIENT_ID": "register-user" }
```
`index.html` (încarcă înainte de app):
```html
<script>
  window.__APP_CONFIG__ = {};
  fetch('/app-config.json').then(r => r.json()).then(c => { window.__APP_CONFIG__ = c; });
</script>
```
În cod folosești `window.__APP_CONFIG__.API_URL` în loc de `import.meta.env.VITE_*`.
În cluster suprascrii fișierul cu un ConfigMap montat peste `/usr/share/nginx/html/app-config.json` → **fără rebuild**.

---

## 6. PAT least-privilege pentru `cd-bump`

**Soluția:** un Fine-grained PAT care poate **doar** push pe `ms-gitops`:
- Repository access: **Only select repositories** → `ms-gitops`
- Permissions: **Contents: Read and write** (atât)
- Expiration: 90 zile
- Salvat ca secret `GITOPS_PAT` pe repo-urile serviciilor.

---

## 7. Prerechizite cluster — manifeste concrete

### 7.1 KafkaTopic `product-topic`
`infra/kafka/topics/product-topic.yaml`:
```yaml
apiVersion: kafka.strimzi.io/v1
kind: KafkaTopic
metadata:
  name: product-topic
  namespace: messaging
  labels: { strimzi.io/cluster: demo }
spec: { partitions: 3, replicas: 1 }
```

### 7.2 Realm `rsk` + client (Crossplane)
`apps/rsk/realm.yaml`:
```yaml
apiVersion: realm.keycloak.crossplane.io/v1alpha1
kind: Realm
metadata: { name: rsk }
spec:
  forProvider: { realm: rsk, enabled: true }
  providerConfigRef: { name: keycloak-provider-config }
---
apiVersion: openidclient.keycloak.crossplane.io/v1alpha1
kind: Client
metadata: { name: register-user }
spec:
  forProvider:
    realmId: rsk
    clientId: register-user
    accessType: CONFIDENTIAL
    standardFlowEnabled: true
  providerConfigRef: { name: keycloak-provider-config }
```

### 7.3 Deployment business (data-service) — wired la operatori
`business/data-service.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: data-service, namespace: business, labels: { app: data-service } }
spec:
  replicas: 1
  selector: { matchLabels: { app: data-service } }
  template:
    metadata:
      labels: { app: data-service }
      annotations:
        co.elastic.logs/json.keys_under_root: "true"
    spec:
      containers:
        - name: data-service
          image: ion21/data-service:latest      # CI bump-uiește SHA-ul
          ports: [ { containerPort: 8081 } ]
          env:
            - { name: SPRING_PROFILES_ACTIVE, value: helm }
            - { name: KAFKA_BOOTSTRAP_SERVERS, value: demo-kafka-bootstrap.messaging.svc:9092 }
            - { name: MYSQL_URL, value: "jdbc:mysql://moco-mysql-primary.data.svc:3306/micro_db?createDatabaseIfNotExist=true&allowPublicKeyRetrieval=true&useSSL=false" }
            - { name: KEYCLOAK_SERVER_URL, value: https://auth.icode.mywire.org }
            - { name: KEYCLOAK_REALM, value: rsk }
            - name: MYSQL_USERNAME
              valueFrom: { secretKeyRef: { name: mysql-app, key: WRITABLE_USER } }
            - name: MYSQL_PASSWORD
              valueFrom: { secretKeyRef: { name: mysql-app, key: WRITABLE_PASSWORD } }
          readinessProbe: { httpGet: { path: /actuator/health, port: 8081 }, initialDelaySeconds: 30 }
---
apiVersion: v1
kind: Service
metadata: { name: data-service, namespace: business }
spec:
  selector: { app: data-service }
  ports: [ { port: 8081, targetPort: 8081 } ]
```

---

## 8. Secrete — SealedSecret + Reflector (MySQL cross-namespace)

MOCO generează secretul `moco-mysql` în ns `data`. Pentru a-l folosi în `business`:
- adnotezi secretul-sursă pt Reflector (oglindire în `business`), **sau**
- creezi un SealedSecret dedicat `mysql-app` în `business` cu user/parolă writable.

```yaml
# adnotări pe secretul sursă (ns data) pt oglindire
metadata:
  annotations:
    reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
    reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "business"
    reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
    reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "business"
```
**Regulă:** niciun `*-secret.yaml`/`-raw.yaml` în git — doar SealedSecret.

---

## 9. Cum se leagă tot (un singur flux)
```
git push (cod serviciu)
  → CI: build-test (Testcontainers) → scan → publish ion21/<svc>:<sha>
  → cd-bump: commit tag în ms-gitops
  → ArgoCD auto-sync: deploy în ns business
  → serviciul se conectează la demo-kafka-bootstrap + MOCO mysql + Keycloak rsk
  → loguri în ELK, mesaje pe product-topic, UI afișează produsele
```
**Asta e „CI/CD bine definit”:** o singură acțiune (push) duce codul testat până în cluster, reproductibil, cu securitate și verificare la fiecare pas.
