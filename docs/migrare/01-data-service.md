# Ghid 1 — Migrare `data-service`

> Ghid de îndrumare. **Tu** (Constantin) execuți pașii; aici ai ce, cum și de ce.
> Premisă: [Ghid 0 — Prerechizite](00-prerechizite.md) e bifat (`product-topic`, realm `rsk`, secret `mysql-app`, ns `business`).

## Sumar serviciu
| | |
|---|---|
| Repo / imagine | `data-service` → `ion21/data-service` |
| Port | `8081` |
| Endpoints | `/api/v1/command` → `getallmap`, `getbyidp/{id}`, `update` |
| Rol | **consumă** evenimente de pe `product-topic` → salvează în MySQL → expune REST |
| Dependențe | Kafka (`demo`), MySQL (MOCO), Keycloak (realm `rsk`) |

## Analiză stare curentă
| Aspect | Stare | Acțiune |
|---|---|---|
| Config DB/Kafka (`application-helm.yaml`) | ✅ env-driven (`${...:default}`) | setezi env la deploy |
| Config JWT (`jwk-set-uri`, `expected-issuer`) | ❌ **hardcodate la `localhost`** (liniile ~20, ~59) | mic fix → env-driven (pasul 1bis) |
| Logging (logback) | ❌ appender **Logstash TCP** (`logstash:5044`) | → JSON stdout (Filebeat) |
| Kafka consumer | ⚠️ `@KafkaListener` pare **comentat** în cod | **verifică/activează** — altfel nu consumă nimic |
| Topic | `product-topic` | ✅ creat la Ghid 0 |

---

## Directive (pas cu pas)

### 1. Verifică/activează consumer-ul Kafka  `P0`
Caută în `data-service/src` listener-ul:
```bash
grep -rn '@KafkaListener' src/main
```
Dacă e comentat (`// @KafkaListener`), **decomentează-l** și asigură-te că topicul vine din config:
```java
@KafkaListener(topics = "${app.kafka.topic}", groupId = "${spring.kafka.consumer.group-id}")
public void onMessage(MessageEvent e) { ... }
```
> Fără asta serviciul pornește „Healthy” dar **nu salvează nimic** — capcană clasică.

### 1bis. Fă endpoint-urile JWT env-driven  `P0`
În `application-helm.yaml`, `jwk-set-uri` și `expected-issuer` sunt **hardcodate la `localhost`** → în cluster JWT-ul nu se validează. Parametrizează-le:
```yaml
app:
  security:
    expected-issuer: ${KEYCLOAK_ISSUER:http://localhost/keycloak/realms/rsk}
spring:
  security:
    oauth2:
      resourceserver:
        jwt:
          jwk-set-uri: ${KEYCLOAK_JWK_SET_URI:http://localhost/keycloak/realms/rsk/protocol/openid-connect/certs}
```

### 2. Treci logging-ul pe Filebeat (JSON stdout)  `P0`
Înlocuiește `src/main/resources/logback-spring.xml`:
```xml
<configuration>
  <include resource="org/springframework/boot/logging/logback/defaults.xml" />
  <springProperty name="APP" source="spring.application.name" defaultValue="data-service" />
  <appender name="JSON" class="ch.qos.logback.core.ConsoleAppender">
    <encoder class="net.logstash.logback.encoder.LogstashEncoder">
      <customFields>{"app_name":"${APP}"}</customFields>
    </encoder>
  </appender>
  <root level="INFO"><appender-ref ref="JSON" /></root>
</configuration>
```
**De ce:** clusterul colectează loguri prin **Filebeat** (stdout), NU are Logstash. Encoder-ul `logstash-logback-encoder` e deja în `pom.xml`. Scoate și `app.elk.logstash-host/port` din `application-helm.yaml` (config mort).

### 3. Testează local  `P0`
```bash
docker compose up -d            # mysql + kafka + keycloak (vezi SOLUTIONS §2)
./mvnw spring-boot:run -Dspring-boot.run.profiles=local
# smoke: http://localhost:8081/swagger-ui.html ; produ un mesaj pe product-topic -> verifică în DB
```

### 4. Adaugă integration test (Testcontainers)  `P0`
Vezi [`SOLUTIONS.md`](SOLUTIONS.md) §3 — un IT care pornește Kafka+MySQL efemere și validează „eveniment → salvat în DB”. Rulează cu `./mvnw verify`.

### 5. Pune pipeline-ul CI/CD serios  `P0`
Înlocuiește `.github/workflows/deploy.yml` cu pipeline-ul din [`SOLUTIONS.md`](SOLUTIONS.md) §1 (`IMAGE: ion21/data-service`): build-test → scan → publish `:<sha>` → cd-bump în gitops.

### 6. Creează manifestul GitOps  `P0`
`business/data-service.yaml` în `ms-gitops` (Deployment + Service). Env-uri cheie:
```yaml
env:
  - { name: SPRING_PROFILES_ACTIVE, value: helm }
  - { name: KAFKA_BOOTSTRAP_SERVERS, value: demo-kafka-bootstrap.messaging.svc:9092 }
  - { name: APP_KAFKA_TOPIC, value: product-topic }
  - { name: MYSQL_URL, value: "jdbc:mysql://moco-mysql-primary.data.svc:3306/micro_db?createDatabaseIfNotExist=true&allowPublicKeyRetrieval=true&useSSL=false" }
  - { name: KEYCLOAK_SERVER_URL, value: https://auth.icode.mywire.org }
  - { name: KEYCLOAK_REALM, value: rsk }
  - { name: KEYCLOAK_ISSUER, value: https://auth.icode.mywire.org/realms/rsk }
  - { name: KEYCLOAK_JWK_SET_URI, value: https://auth.icode.mywire.org/realms/rsk/protocol/openid-connect/certs }
  - name: MYSQL_USERNAME
    valueFrom: { secretKeyRef: { name: mysql-app, key: WRITABLE_USER } }
  - name: MYSQL_PASSWORD
    valueFrom: { secretKeyRef: { name: mysql-app, key: WRITABLE_PASSWORD } }
```
+ adnotări pod pentru Filebeat:
```yaml
co.elastic.logs/json.keys_under_root: "true"
co.elastic.logs/json.message_key: "message"
```
Manifest complet model în [`SOLUTIONS.md`](SOLUTIONS.md) §7.3.

### 7. Deploy + verify  `P0`
- `git push` în `data-service` → CI buildează + bump-uiește gitops → ArgoCD deployează.
- Verifică:
```bash
kubectl -n business get pods                       # data-service Running
kubectl -n business logs deploy/data-service | head # JSON, fără erori Logstash
kubectl -n messaging get kafkatopic product-topic
```
- Smoke: prin Kong, `GET /api/v1/command/getallmap` cu Bearer (token din realm `rsk`).
- Kibana: logurile `data-service` apar.

---

## Gotchas specifice
- **`@KafkaListener` comentat** → nu consumă (vezi pasul 1).
- `micro_db` se creează singur (`createDatabaseIfNotExist=true`) cu userul `moco-writable` (are CREATE).
- `value.default.type` din config = `com.example.data_service.model.MessageEvent` → trebuie să fie ACELAȘI tip cu ce trimite importer-ul (altfel deserialization fail).

## Definition of Done
- [ ] consumer Kafka activ · [ ] JWT env-driven · [ ] logback JSON · [ ] test local + Testcontainers · [ ] CI verde
- [ ] `business/data-service.yaml` · [ ] ArgoCD Synced+Healthy · [ ] smoke prin Kong OK

➡️ Gata? Treci la [Ghid 2 — importer-service](02-importer-service.md).
