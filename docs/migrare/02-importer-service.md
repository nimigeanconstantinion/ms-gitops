# Ghid 2 — Migrare `importer-service`

> Ghid de îndrumare. **Tu** execuți. Acest serviciu cere **fix de config înainte** (e hardcodat).
> Premisă: [Ghid 0](00-prerechizite.md) bifat + [Ghid 1 — data-service](01-data-service.md) live (importer publică spre el).

## Sumar serviciu
| | |
|---|---|
| Repo / imagine | `importer-service` → `ion21/import-service` |
| Port | `8082` |
| Endpoints | `/api/v1/query` → `""`, `/sync`, `/byid/{id}` |
| Rol | importă produse → **publică** evenimente pe `product-topic`; scrie și în MySQL |
| Dependențe | Kafka (`demo`), MySQL (MOCO), Keycloak (realm `rsk`) |

## Analiză stare curentă
| Aspect | Stare | Severitate |
|---|---|---|
| Config (`application-helm.yaml`) | ❌ **HARDCODAT**: `jdbc:mysql://78.96.25.131:3306/test_db`, parolă `R@0t`, Kafka `localhost:30001`, Keycloak `localhost` | 🔴 blocant |
| Parolă plain `R@0t` în git (repo public) | 🔴 leak | rotire obligatorie |
| Logging (logback) | ❌ appender Logstash TCP | 🟡 |
| Are `docker-compose.yaml` | ✅ | bun pt test local |

---

## Directive (pas cu pas)

### 1. ⚠️ Fă config-ul env-driven (OBLIGATORIU întâi)  `P0`
În `src/main/resources/application-helm.yaml`, înlocuiește valorile fixe cu `${ENV:default}` (ca data-service):
```yaml
spring:
  datasource:
    url: ${MYSQL_URL:jdbc:mysql://localhost:3306/micro_db}
    username: ${MYSQL_USERNAME:root}
    password: ${MYSQL_PASSWORD:root}
  kafka:
    bootstrap-servers: ${KAFKA_BOOTSTRAP_SERVERS:localhost:9092}
  security:
    oauth2:
      resourceserver:
        jwt:
          jwk-set-uri: ${KEYCLOAK_JWK_SET_URI}
app:
  security:
    expected-issuer: ${KEYCLOAK_ISSUER}
  kafka:
    topic: ${APP_KAFKA_TOPIC:product-topic}
```
**Scoate complet:** IP-ul `78.96.25.131`, `test_db`, parola `R@0t`. Niciun secret în cod.

### 2. 🔒 Rotește parola scursă  `P0`
`R@0t` a fost în git public → schimb-o în MySQL + folosește noua valoare DOAR prin Secret (K8s). Vechiul commit rămâne în istoric (ideal `git filter-repo`, minim rotire).

### 3. Treci logging-ul pe Filebeat (JSON stdout)  `P0`
Identic cu [Ghid 1, pasul 2](01-data-service.md) — `logback-spring.xml` cu `ConsoleAppender` + `LogstashEncoder`, scoate appender-ul Logstash TCP + `app.elk.logstash-*` din config.

### 4. Testează local  `P0`
```bash
docker compose up -d        # folosește compose-ul existent din repo
./mvnw spring-boot:run -Dspring-boot.run.profiles=local
# smoke: GET http://localhost:8082/api/v1/query/sync -> verifică mesaj pe product-topic
```

### 5. Integration test (Testcontainers)  `P0`
IT care validează „import → **publică** pe product-topic” (KafkaContainer). Plus, dacă vrei lanț complet, pornește și data-service în test. Vezi [`SOLUTIONS.md`](SOLUTIONS.md) §3.

### 6. Pipeline CI/CD serios  `P0`
Pipeline-ul din [`SOLUTIONS.md`](SOLUTIONS.md) §1 cu `IMAGE: ion21/import-service`.

### 7. Manifest GitOps  `P0`
`business/importer-service.yaml` (Deployment+Service, port 8082) cu aceleași env ca data-service (Kafka/MySQL/Keycloak) + adnotările Filebeat. Model: [`SOLUTIONS.md`](SOLUTIONS.md) §7.3.

### 8. Deploy + verify — lanțul complet  `P0`
```bash
kubectl -n business get pods                    # importer-service Running
# trigger import:
curl -H "Authorization: Bearer <token-rsk>" https://app.icode.mywire.org/api/v1/query/sync
```
→ importer publică pe `product-topic` → **data-service consumă** → produs în MySQL → vizibil în UI/data-service. **Asta validează tot lanțul.**

---

## Gotchas specifice
- Config-ul hardcodat e cel mai mare risc — **nu deploya până nu e env-driven** (altfel se conectează la IP-uri/DB greșite).
- `test_db` vs `micro_db`: aliniază importer și data pe **aceeași** bază (`micro_db`).
- Tipul mesajului publicat trebuie să fie cel pe care data-service îl deserializează (`MessageEvent`).

## Definition of Done
- [ ] config env-driven, zero hardcodări · [ ] `R@0t` rotit · [ ] logback JSON
- [ ] test local + Testcontainers · [ ] CI verde · [ ] `business/importer-service.yaml`
- [ ] ArgoCD Synced+Healthy · [ ] lanț complet importer→data verificat

➡️ Gata? Treci la [Ghid 3 — client / UI](03-client-ui.md).
