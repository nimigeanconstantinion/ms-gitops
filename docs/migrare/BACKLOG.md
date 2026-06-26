# Backlog — Migrare microservicii în GitOps cu CI/CD bine definit

> **Scop:** un pipeline **CI/CD serios și bine definit** pentru cele 3 microservicii (`data-service`, `importer-service`, `client/UI`), migrate **serviciu cu serviciu** în clusterul GitOps.
> Context: [`services-communication.pdf`](../diagrame/services-communication.pdf) · [`MIGRATION_PLAN.md`](MIGRATION_PLAN.md).
>
> **Convenții:** `CTIN-Exx` = Epic · `CTIN-Sxxx` = Story · Prioritate `P0`(critic)→`P3` · Mărime `S`/`M`/`L`.
> Fiecare story are **Descriere**, **Acceptance Criteria** (AC) și **Tasks**.

---

## Ordinea sprinturilor (recomandată)
1. **Sprint 1:** E0 (prerechizite) + E1 (pipeline standard) + E2 (testare locală) → fundația
2. **Sprint 2:** E3 (data-service end-to-end) → primul serviciu, validează tot lanțul
3. **Sprint 3:** E4 (importer) + E5 (UI)
4. **Continuu:** E6 (securitate), E7 (verificare E2E)

---

# EPIC CTIN-E0 — Prerechizite cluster & GitOps  `P0`
**Obiectiv:** infra și artefactele de care depind TOATE serviciile, puse o singură dată.

### CTIN-S001 — KafkaTopic `product-topic`  `P0` `S`
**Ca** platformă, **vreau** topicul `product-topic` în Kafka, **ca** importer să poată publica și data-service să consume.
**Descriere:** serviciile folosesc `product-topic` (hardcodat în config); în cluster ai doar `orders/events/notifications`.
**AC:**
- `infra/kafka/topics/product-topic.yaml` (KafkaTopic, cluster `demo`, ns `messaging`)
- `kubectl -n messaging get kafkatopic product-topic` → Ready
**Tasks:** scrie manifestul · commit gitops · Sync app `kafka` · verifică în Kafka UI.

### CTIN-S002 — Realm `rsk` + client `register-user` (declarativ)  `P0` `M`
**Ca** serviciu, **vreau** realm-ul `rsk` cu clientul `register-user`, **ca** validarea JWT să funcționeze.
**Descriere:** apps validează token pe realm `rsk`; ai doar `demo`. `apps/` (Crossplane) e gol.
**AC:**
- realm `rsk` + client `register-user` + roles definite în `apps/rsk/` (Crossplane Realm/Client/Role)
- `kubectl get realm,client -A` → Synced
- token emis de `rsk` e acceptat de servicii (jwk-set-uri rezolvă)
**Tasks:** Realm CR · Client CR (+ secret) · Roles · commit · Sync `keycloak-realms`.

### CTIN-S003 — Secret MySQL pentru business (Reflector)  `P0` `S`
**Ca** serviciu, **vreau** credențialele MOCO oglindite în ns `business`, **ca** să mă conectez la DB.
**AC:** secret `mysql-app` în ns `business` (oglindit din `data` via Reflector) cu user/parolă writable.
**Tasks:** adnotări Reflector pe secretul MOCO · verifică oglindirea.

### CTIN-S004 — Namespace `business` + Application App-of-Apps  `P0` `S`
**AC:** `argo-apps/app-business.yaml` (wave 5, ns `business`, path `business/`, recurse) · ns creat · ArgoCD vede folderul.
**Tasks:** Application manifest · commit · verifică în ArgoCD.

### CTIN-S005 — Secrete CI (`DOCKERHUB_*`) per repo  `P0` `S`
**AC:** `DOCKERHUB_USERNAME` + `DOCKERHUB_TOKEN` setate pe repo-urile `importer-service`, `data-service`, `client-microserv-vite`.
**Tasks:** creează token Docker Hub (`ion21`) · `gh secret set` pe fiecare repo.

---

# EPIC CTIN-E1 — Pipeline CI/CD standard & reutilizabil  `P0`  ⭐ (scopul principal)
**Obiectiv:** un pipeline **identic, serios** pe toate serviciile: lint → build → **test** → scan → publish → **CD-bump**. Înlocuiește `deploy.yml` actual (doar build+push, zero teste).

### CTIN-S101 — Job `build-test` (compile + unit)  `P0` `M`
**Ca** echipă, **vreau** ca CI să compileze și să ruleze testele unitare, **ca** să nu publicăm imagini stricate.
**Descriere:** azi `deploy.yml` sare peste teste. Adăugăm un job care eșuează dacă build-ul/testele pică.
**AC:**
- job `build-test`: checkout → setup JDK 17 → `./mvnw -B verify`
- pipeline-ul **se oprește** dacă testele pică (publish nu rulează)
- rulează pe `push` (master + PR)
**Tasks:** scrie jobul · cache Maven · rulează pe PR + master.

### CTIN-S102 — Integration tests cu Testcontainers  `P0` `L`
**Ca** dezvoltator, **vreau** teste de integrare cu Kafka+MySQL efemere, **ca** să validez fluxul real fără infra externă.
**Descriere:** test „importer publică → data consumă → salvează în DB” cu containere pornite în test.
**AC:**
- dependență `org.testcontainers` (kafka, mysql) în `pom.xml`
- ≥1 `@Testcontainers` IT per serviciu (Kafka + MySQL prin `@DynamicPropertySource`)
- rulează în jobul `build-test` (CI), verde
**Tasks:** add deps · scrie IT data-service · scrie IT importer · integrează în `mvn verify`.

### CTIN-S103 — Image scan (Trivy)  `P1` `S`
**Ca** echipă, **vreau** scan de vulnerabilități pe imagine, **ca** să nu publicăm CVE critice.
**AC:** job `scan` cu `aquasecurity/trivy-action` → `--severity CRITICAL,HIGH` → fail pe CRITICAL.
**Tasks:** add job · prag configurabil · raport în PR.

### CTIN-S104 — Publish multiarch cu tag imutabil  `P0` `M`
**Ca** echipă, **vreau** imagini taguite cu git SHA (nu doar `latest`), **ca** GitOps să poată fixa o versiune exactă.
**Descriere:** azi tag = dată (`BUILD_NUMBER`). Trecem pe `:${GITHUB_SHA::7}` + `:latest`.
**AC:**
- buildx → `ion21/<svc>:<sha7>` **și** `:latest`, platforme amd64+arm64
- SHA-ul devine output al jobului (pt CD-bump)
**Tasks:** refactor `build-publish.sh`/workflow · output `image_tag` · push ambele taguri.

### CTIN-S105 — Job `cd-bump` — închide bucla CI→CD  `P0` `L`
**Ca** echipă, **vreau** ca, după publish, CI să actualizeze tag-ul imaginii în `ms-gitops`, **ca** ArgoCD să deployeze automat versiunea nouă.
**Descriere:** fără asta, imaginea nouă există în registry dar clusterul rulează tag-ul vechi. Jobul face commit în gitops cu noul SHA.
**AC:**
- job `cd-bump` (rulează doar pe `master`, după publish): checkout `ms-gitops` → `sed` tag în `business/<svc>.yaml` → `git commit` + `push`
- folosește un PAT cu drept de push pe `ms-gitops` (least-privilege: doar acel repo, Contents:Write)
- ArgoCD (auto-sync) deployează în <5 min
**Tasks:** PAT bot + secret · job cd-bump · sed pe tag · test end-to-end (push cod → cluster).

### CTIN-S106 — Branch protection + PR checks  `P1` `S`
**Ca** echipă, **vreau** ca `master` să accepte doar PR-uri cu CI verde, **ca** să nu intre cod nestestat.
**AC:** branch protection pe `master`: require `build-test` pass + ≥1 review. `cd-bump` doar pe master.
**Tasks:** config GitHub branch protection per repo.

### CTIN-S107 — Workflow reutilizabil (DRY)  `P2` `M`
**Ca** echipă, **vreau** un singur workflow reutilizabil (`workflow_call`) consumat de cele 3 repo-uri, **ca** să nu duplic pipeline-ul.
**AC:** un `reusable-ci.yml` (într-un repo central) apelat din fiecare serviciu cu parametri (REPO, dockerfile, lang).
**Tasks:** extrage workflow reutilizabil · parametrizează · adoptă în 3 repo-uri.

---

# EPIC CTIN-E2 — Testare locală (per microserviciu)  `P0`
**Obiectiv:** fiecare serviciu rulabil/izolat local înainte de push.

### CTIN-S201 — `docker-compose` local cu dependențe  `P0` `M`
**Ca** dezvoltator, **vreau** un compose care pornește Kafka+MySQL+Keycloak local, **ca** să rulez serviciul end-to-end pe laptop.
**AC:** `docker-compose.yaml` (kafka, mysql, keycloak cu realm `rsk` importat) · `docker compose up` → toate up · serviciul pornește pe profil `local` și se conectează.
**Tasks:** compose · realm `rsk` export pt Keycloak local · README cu pașii.

### CTIN-S202 — Profil Spring `local` curat  `P1` `S`
**AC:** `application-local.yaml` pointează la `localhost` (compose); fără secrete hardcodate.
**Tasks:** profil local · documentează `-Dspring-boot.run.profiles=local`.

### CTIN-S203 — Smoke test reproductibil  `P2` `S`
**AC:** colecție Postman / script `curl` care: ia token din Keycloak local → POST `/import` → verifică în data-service GET că produsul apare.
**Tasks:** script smoke · documentează în README.

### CTIN-S204 — UI: dev + runtime config  `P1` `M`
**Ca** dezvoltator UI, **vreau** `npm run dev` cu backend local și **runtime config** pt cluster, **ca** să nu rebuild-uiesc imaginea per mediu.
**AC:** `.env.local` (negit) pt dev · UI citește `app-config.json` la runtime (nu doar `VITE_*` build-time) · `npm run build && preview` ok.
**Tasks:** runtime config loader · `.env` scos din git · documentat.

---

# EPIC CTIN-E3 — Migrare `data-service`  `P0`  (primul serviciu)
**Obiectiv:** primul serviciu live în cluster prin pipeline — validează tot lanțul. E env-driven → cel mai ușor.

### CTIN-S301 — data-service rulează local  `P0` `S`
**AC:** `mvn spring-boot:run -Plocal` + compose → consumă de pe `product-topic`, salvează în MySQL local.

### CTIN-S302 — CI complet pe data-service  `P0` `M`
**AC:** `deploy.yml` migrat la pipeline-ul E1 (build-test + Testcontainers + publish SHA + cd-bump). Push pe master → imagine + bump în gitops.

### CTIN-S303 — Manifest GitOps data-service  `P0` `M`
**AC:** `business/data-service.yaml` (Deployment+Service) cu env: `SPRING_PROFILES_ACTIVE=helm`, `KAFKA_BOOTSTRAP_SERVERS=demo-kafka-bootstrap.messaging.svc:9092`, `MYSQL_URL` (MOCO), `KEYCLOAK_*` (realm `rsk`). Readiness pe `/actuator/health`.
**Tasks:** Deployment+Service · env din ConfigMap/Secret · probe.

### CTIN-S304 — data-service Synced + Healthy  `P0` `S`
**AC:** ArgoCD app `business` Synced+Healthy · pod Running · `/swagger-ui.html` accesibil prin Kong · consumă din `product-topic`.

---

# EPIC CTIN-E4 — Migrare `importer-service`  `P1`
**Obiectiv:** al doilea serviciu — necesită fix config (e hardcodat).

### CTIN-S401 — Fix config importer (env-driven)  `P0` `M`
**Ca** echipă, **vreau** importer parametrizat prin env, **ca** să-l pot deploya în orice mediu fără rebuild.
**Descriere:** `application-helm.yaml` are hardcodat IP `78.96.25.131`, parolă plain `R@0t`, `localhost` la Kafka/Keycloak.
**AC:** toate endpoint-urile pe `${ENV:default}` (ca data-service) · zero secrete în cod.
**Tasks:** refactor `application-helm.yaml` · scoate `R@0t` · rotește parola.

### CTIN-S402 — CI complet pe importer  `P1` `M` — *(la fel ca S302)*
### CTIN-S403 — Manifest GitOps importer  `P1` `M`
**AC:** `business/importer-service.yaml` cu env Kafka/MySQL/Keycloak. Publică pe `product-topic`.
### CTIN-S404 — Lanț complet validat  `P1` `S`
**AC:** importer publică → data-service consumă → produs în DB → vizibil în UI. (smoke E2E)

---

# EPIC CTIN-E5 — Migrare `client/UI`  `P2`
### CTIN-S501 — UI runtime config + scos `.env`  `P1` `M`
**AC:** UI citește `app-config.json` la runtime; `.env` în `.gitignore`; build curat.
### CTIN-S502 — CI complet pe UI  `P2` `S`
**AC:** pipeline E1 adaptat (lint+build+publish+cd-bump); rulează pe `feat/**` + master.
### CTIN-S503 — Manifest GitOps UI + Ingress  `P2` `M`
**AC:** `business/client.yaml` + ConfigMap `app-config.json` (API + Keycloak `rsk`) + Ingress `app.icode.mywire.org` (TLS).
### CTIN-S504 — UI live & funcțional  `P2` `S`
**AC:** `https://app.icode.mywire.org` → login Keycloak (`rsk`) → afișează produse.

---

# EPIC CTIN-E6 — Securitate & hardening  `P1`  (transversal)
### CTIN-S601 — Elimină secretele din cod/git  `P0` `S`
**AC:** `R@0t` scos + rotit; `.env` UI scos; `.gitignore` corect; zero `*-secret.yaml` în git.
### CTIN-S602 — PAT least-privilege pt cd-bump  `P1` `S`
**AC:** token bot doar pe `ms-gitops`, Contents:Write, expirare 90 zile.
### CTIN-S603 — NetworkPolicies default-deny ns `business`  `P2` `M`
**AC:** trafic restricționat; business ajunge doar la messaging/data/auth necesare.

---

# EPIC CTIN-E7 — Verificare end-to-end & observability  `P2`
### CTIN-S701 — Dashboard fluxul în Kafka UI + Grafana  `P2` `S`
**AC:** vezi mesajele pe `product-topic` în Kafka UI; metrici servicii în Grafana.
### CTIN-S702 — Loguri în Kibana  `P2` `S`
**AC:** logurile celor 3 servicii apar în Kibana (prin Filebeat), structurate.
### CTIN-S703 — Smoke E2E automatizat  `P3` `M`
**AC:** un test (curl/Playwright) rulează lanțul complet în cluster după deploy.

---

## Rezumat — ce înseamnă „CI/CD bine definit” aici
| Etapă | Înainte (actual) | După (definit) |
|---|---|---|
| Test | ❌ niciun test | ✅ unit + integration (Testcontainers) |
| Build | buildx push | buildx push, tag **SHA** imutabil |
| Securitate | ❌ | ✅ Trivy scan + secrete doar sealed |
| CD | ❌ manual | ✅ **cd-bump** auto în gitops → ArgoCD |
| Calitate | push direct | ✅ PR + branch protection + CI gate |
| Local | ad-hoc | ✅ compose + Testcontainers reproductibil |
