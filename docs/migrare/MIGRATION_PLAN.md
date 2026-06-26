# Plan de migrare — layer business → GitOps (serviciu cu serviciu)

> Scop: aducem cele 3 microservicii (`data-service`, `importer-service`, `client/UI`) în clusterul GitOps, **unul câte unul**, fiecare cu **CI/CD serios** + **testare locală** înainte de deploy.
> Diagrama de comunicare: [`services-communication.pdf`](../diagrame/services-communication.pdf).
> Infra (Kafka/MySQL/Keycloak/ELK) e deja prin **operatori** — NU folosim umbrella `ubuntu-microservicii-helm` întreg (ar dubla infra).

---

## 0. Principii

1. **Serviciu cu serviciu**, nu big-bang. Fiecare e independent: test local → CI verde → deploy GitOps → verificat în cluster → abia apoi următorul.
2. **Definition of Done** per serviciu (vezi §6) — nu trecem mai departe până nu e bifat.
3. **12-factor**: config prin env/ConfigMap la deploy, NU hardcodat în imagine.
4. **Imagini imutabile**: tag = git SHA (nu `latest` în producție; `latest` doar comoditate).

**Ordine (din analiză):** `data-service` (e env-driven) → `importer-service` (după fix config) → `UI` (după rebuild). Înainte de toate: **prerechizitele**.

---

## 1. Prerechizite în cluster (o singură dată)

| # | Ce | Unde | De ce |
|---|---|---|---|
| 1 | KafkaTopic **`product-topic`** | `infra/kafka/topics/` | serviciile produc/consumă pe el (ai doar orders/events/notifications) |
| 2 | Realm **`rsk`** + client `register-user` + roles | `apps/<rsk>/` (Crossplane) | apps validează JWT pe realm `rsk` (ai doar `demo`) |
| 3 | Secret MySQL pt business | Reflector `data` → `business` | serviciile au nevoie de user/parolă MOCO |
| 4 | `DOCKERHUB_USERNAME` + `DOCKERHUB_TOKEN` | per repo GitHub (importer/data/ui) | CI să poată push la `ion21/*` |
| 5 | ns **`business`** + Application `app-of-apps` | `argo-apps/app-business.yaml` | container pt serviciile business (wave 5) |

---

## 2. CI/CD pipeline serios (template per serviciu)

Ce au **acum**: `deploy.yml` = doar build + push (zero teste, tag dată). Insuficient.

Ce vrem (4 joburi):

```
┌─ 1. build-test ──────────────────────────────────────────────┐
│  checkout → setup JDK 17 → ./mvnw verify                       │
│  (compile + unit + integration cu Testcontainers)              │
│  FAIL → oprește pipeline-ul (nu publici imagini stricate)      │
├─ 2. scan (opțional, recomandat) ─────────────────────────────┤
│  Trivy pe imaginea buildată → fail pe CVE critice              │
├─ 3. publish ─────────────────────────────────────────────────┤
│  buildx multiarch → push ion21/<svc>:${GIT_SHA} + :latest      │
│  (tag SHA = imutabil; latest = comoditate)                     │
├─ 4. cd-bump (GitOps) ────────────────────────────────────────┤
│  checkout ms-gitops → sed image tag în Deployment →            │
│  git commit + push → ArgoCD auto-sync deployează               │
└──────────────────────────────────────────────────────────────┘
```

**De ce jobul 4 (cd-bump):** închide bucla CI→CD. Fără el, imaginea nouă există în registry dar clusterul rulează tag-ul vechi. Cu el: `git push` în cod → automat ajunge în cluster.

> Pentru UI (Vite): jobul 1 = `npm ci && npm run lint && npm run build` (+ `type-check`).

---

## 3. Testare locală (cum testezi FIECARE microserviciu)

### Strategia generală
Fiecare serviciu trebuie să poată rula **izolat**, cu dependențele pornite local. Trei niveluri:

| Nivel | Unealtă | Când |
|---|---|---|
| **Unit** | JUnit / Vitest | la fiecare modificare, rapid |
| **Integration** | **Testcontainers** (Kafka, MySQL efemere) | în CI, fără infra externă |
| **End-to-end local** | **docker-compose** (Kafka+MySQL+Keycloak) | înainte de push, smoke manual |

### data-service / importer-service (Spring Boot)
**a) docker-compose local** (dependențe reale, efemere):
```bash
# docker-compose.yaml cu: kafka (redpanda/bitnami), mysql, keycloak
docker compose up -d kafka mysql keycloak
./mvnw spring-boot:run -Dspring-boot.run.profiles=local
# smoke: Swagger la http://localhost:<port>/swagger-ui.html
```
**b) Integration tests cu Testcontainers** (rulează și în CI, fără docker-compose):
```java
@Testcontainers
class DataServiceIT {
  @Container static KafkaContainer kafka = new KafkaContainer(...);
  @Container static MySQLContainer<?> mysql = new MySQLContainer<>("mysql:8.0");
  // @DynamicPropertySource -> spring.kafka.bootstrap-servers / datasource.url
}
```
→ test real de „importer publică → data consumă → salvează în DB”, complet izolat.

### client / UI (React + Vite)
```bash
# .env.local (NEcommis) cu backend local:
#   VITE_APP_API_URL=http://localhost:5000
#   VITE_KEYCLOAK_URL=http://localhost:8085
npm ci
npm run dev        # dev server cu hot-reload, pointat la backend local
npm run build && npm run preview   # verifici build-ul de producție
```
> ⚠️ Vite injectează `VITE_*` la **build-time** → pentru cluster: ori rebuild cu URL-urile cluster, ori **runtime config** (`app-config.json` servit de nginx + citit de app).

---

## 4. Migrarea pas cu pas

### Pas 1 — `data-service` (primul, e env-driven) ✅ cel mai ușor
1. **Local:** docker-compose (mysql+kafka+keycloak) → `mvn spring-boot:run -Plocal` → postezi pe `product-topic`, verifici că salvează în MySQL.
2. **CI:** adaugă jobul `build-test` (Testcontainers) în `deploy.yml`.
3. **Deploy GitOps:** `business/data-service.yaml` (Deployment+Service) cu env:
   - `SPRING_PROFILES_ACTIVE=helm`
   - `KAFKA_BOOTSTRAP_SERVERS=demo-kafka-bootstrap.messaging.svc:9092`
   - `MYSQL_URL=jdbc:mysql://moco-mysql-primary.data.svc:3306/micro_db?...`
   - `MYSQL_USERNAME/PASSWORD` din secret (Reflector)
   - `KEYCLOAK_SERVER_URL=https://auth.icode.mywire.org`, `KEYCLOAK_REALM=rsk`
4. **Verify:** pod Running, `/swagger-ui.html` prin Kong, consumă din `product-topic`.

### Pas 2 — `importer-service` (după fix config)
1. **Fix cod (obligatoriu):** `application-helm.yaml` e hardcodat — fă-l env-driven ca data-service:
   - scoate `jdbc:mysql://78.96.25.131:3306/test_db` + parola plain `R@0t` → `${MYSQL_URL}` / `${MYSQL_PASSWORD}`
   - `localhost:30001` → `${KAFKA_BOOTSTRAP_SERVERS}`
   - `localhost/keycloak` → `${KEYCLOAK_...}`
2. **Local + CI:** la fel ca data-service.
3. **Deploy GitOps:** `business/importer-service.yaml` cu aceleași env.
4. **Verify:** importer publică pe `product-topic` → data-service consumă (lanț complet).

### Pas 3 — `client/UI` (după rebuild)
1. **Fix:** scoate `.env` din git; treci pe **runtime config** (`app-config.json` montat ca ConfigMap) SAU rebuild cu URL-urile cluster.
2. **Local:** `npm run dev`.
3. **CI:** `build-test` (lint + build) — CI deja se declanșează pe `feat/**`.
4. **Deploy GitOps:** `business/client.yaml` + Ingress `app.icode.mywire.org` + ConfigMap `app-config.json` (API=`https://app.icode.mywire.org/api`, Keycloak=`https://auth.icode.mywire.org`, realm `rsk`).
5. **Verify:** UI live, login Keycloak, afișează produse.

---

## 5. Securitate (transversal)
- Scoate parola plain `R@0t` din `importer` + rotește-o.
- Scoate `.env` (UI) din git → `.gitignore`.
- Secrete cluster doar prin SealedSecret (niciun `*-secret.yaml`/`-raw.yaml` în git).

---

## 6. Definition of Done (per serviciu)
- [ ] Config env-driven (zero hardcodări, zero secrete în cod)
- [ ] Rulează local (docker-compose) + are integration test (Testcontainers)
- [ ] CI: build-test verde → imagine `ion21/<svc>:<sha>` în registry
- [ ] Manifest GitOps în `business/` + tag actualizat de CI
- [ ] ArgoCD: Application **Synced + Healthy**
- [ ] Smoke în cluster: endpoint accesibil prin Kong + JWT valid (realm `rsk`)

---

## 7. Următorul pas concret
Începem cu **prerechizitele** (§1): topic `product-topic` + realm `rsk`. Apoi **`data-service`**. Le facem unul câte unul.
