# Code Review — layer business (chart `microservice` + `data-service`)

> Scope: fișierele adăugate la migrarea primului serviciu — `business/charts/microservice/`, `business/data-service/values.yaml`, `argo-apps/*data-service*.yaml`.
> Data: 2026-07-07 · Branch: `master` · Referință: [`docs/migrare/MIGRATION_PLAN.md`](docs/migrare/MIGRATION_PLAN.md).

---

## Sumar

Infra e matură; problemele sunt izolate în stratul business nou. Un singur bug blochează deploy-ul, restul sunt fragilitate + curățenie.

| # | Severitate | Fișier | Problemă |
|---|---|---|---|
| F1 | 🔴 Critical | `argo-apps/app-data-service.yaml` | data-service definit de 2 ori; copia din `microserv-products` nu pornește |
| F2 | 🟠 High | `infra/databases/secrets/mysql-secret-sealed.yaml` | `mysql-app` static, decuplat de parola rotativă MOCO |
| F3 | 🟠 High (verify) | `business/data-service/values.yaml:24` | realm `rsk` trebuie `Synced`, altfel JWT pică |
| F4 | 🟡 Medium | `argo-apps/app-data-service.yaml` vs `business-data-service.yaml` | `syncOptions` inconsistent (`ServerSideApply` doar pe unul) |
| F5 | ⚪ Low | `business/charts/microservice/` | chart fără `_helpers.tpl`, label-uri standard, `NOTES.txt` |
| F6 | ⚪ Low | `docs/migrare/*` | docs spun „prin Kong", chart-ul folosește nginx Ingress |
| F7 | ⚪ Low | `bootstrap/root.yaml:15` | comentariu leftover din starter |

---

## 🔴 F1 — data-service definit de două ori (unul rupt)

Există două `Application` pentru același serviciu, cu același `releaseName` și același chart+values:

| Fișier | `destination.namespace` | `ServerSideApply` |
|---|---|---|
| `argo-apps/business-data-service.yaml` | `business` | ✅ |
| `argo-apps/app-data-service.yaml` | `microserv-products` | ❌ |

Copia din `microserv-products` nu pornește:

```
CreateContainerConfigError: secret "mysql-app" not found
```

**Cauză:** SealedSecret `mysql-app` (ns `data`) e reflectat **doar** în `business`:

```yaml
# infra/databases/secrets/mysql-secret-sealed.yaml:15,17
reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: business
reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: business
```

`secretEnv` din values cere acel secret în namespace-ul pod-ului:

```yaml
# business/data-service/values.yaml:27-28
MYSQL_USERNAME: { secret: mysql-app, key: WRITABLE_USER }
MYSQL_PASSWORD: { secret: mysql-app, key: WRITABLE_PASSWORD }
```

**Fix:** șterge `argo-apps/app-data-service.yaml`. Sursa de adevăr (values + Reflector target) e ns `business`, deci `business-data-service.yaml` rămâne.

```bash
rm argo-apps/app-data-service.yaml
git commit -am "fix(gitops): drop duplicate data-service app (microserv-products)"
```

Verifică după sync că nu rămâne orphan:

```bash
kubectl get ns microserv-products
kubectl -n microserv-products get deploy,pod
```

---

## 🟠 F2 — `mysql-app` decuplat de MOCO

`mysql-app` e un SealedSecret **static** (parolă fixă). MOCO **regenerează** parola user-ului writable (`moco-mysql`) la fiecare (re)creare de cluster. Când nu coincid:

```
Access denied for user 'moco-writable'@'%'
```

Commit-ul `changed mysql-app secret` din istoric confirmă că problema a mai apărut.

| Opțiune | Efort | Rezultat |
|---|---|---|
| **Reflectă direct `moco-mysql`** (redenumit) în `business` | mic | mereu în sync cu MOCO, o singură sursă |
| Fixează parola writable în CR-ul MOCO + păstrează sealed | mediu | controlezi tu parola |

**Recomandat:** prima variantă — elimini secretul paralel, dispare drift-ul. Adnotările Reflector se pun pe secretul `moco-mysql` (nu e gestionat de tine, dar poți patch-ui via `MySQLCluster.spec` sau un `kustomize`/reflector `reflection-auto`).

---

## 🟠 F3 — realm `rsk` (de verificat live)

`values.yaml` cere realm `rsk` pe toate căile Keycloak:

```yaml
# business/data-service/values.yaml:24-28
KEYCLOAK_REALM: rsk
KEYCLOAK_ISSUER: https://auth.icode.mywire.org/realms/rsk
KEYCLOAK_JWK_SET_URI: https://auth.icode.mywire.org/realms/rsk/protocol/openid-connect/certs
```

`apps/realm.yaml` definește deja `Realm rsk` + `Client register-user` (Crossplane), dar `NEXT_STEPS.md` notează că Crossplane încă nu producea niciun Realm. Dacă CR-ul nu e `Synced`, `jwk-set-uri` întoarce 404 și pornirea validării JWT eșuează.

**Verify:**

```bash
kubectl get realm,client -A            # rsk + register-user => SYNCED=True
curl -s https://auth.icode.mywire.org/realms/rsk/protocol/openid-connect/certs | head
```

---

## 🟡 F4 — `syncOptions` inconsistent

`business-data-service.yaml` are `ServerSideApply=true`, `app-data-service.yaml` nu. E un simptom al duplicării (F1) — două versiuni divergente ale aceluiași manifest. Se rezolvă odată cu ștergerea copiei. Păstrează `ServerSideApply=true` (necesar pentru CR-uri mari / drift MOCO).

---

## ⚪ F5 — igiena chart-ului `microservice`

Funcțional, dar sub convenția din car-platform:

- lipsă `templates/_helpers.tpl` → nume + label-uri duplicate în fiecare template.
- label-uri minime (`app: {{ .Release.Name }}`); lipsesc `app.kubernetes.io/name`, `app.kubernetes.io/managed-by` — le folosesc Prometheus/Kibana pentru corelare.
- lipsă `NOTES.txt`.
- `ingress.yaml` nu are guard pe `host`/`tlsSecretName` gol; e acoperit acum de `enabled: false`, dar la primul serviciu cu Ingress (UI) produce un manifest invalid dacă uiți câmpurile.

Nu blochează nimic — de curățat înainte de a-l reutiliza pe importer + UI.

---

## ⚪ F6 — docs vs implementare (Kong)

`MIGRATION_PLAN.md` / `BACKLOG.md` scriu „accesibil prin Kong", dar chart-ul expune prin **nginx Ingress** (`className: nginx`). Kong e P6/viitor. Aliniază textul sau marchează explicit „Kong = fază ulterioară".

---

## ⚪ F7 — leftover starter

```yaml
# bootstrap/root.yaml:15
targetRevision: master   # SAU master — ajustează după branch-ul real al repo-ului
```

Comentariu rămas din template (branch-ul e clar `master`). Șterge.

---

## Ce e bine (de păstrat)

- Multi-source `$values` pattern corect pe `business-data-service.yaml` (chart + values din același repo, `ref: values`).
- Tag imutabil `d36d509` pus de CI, fără `:latest` în cluster — exact ținta din `MIGRATION_PLAN.md §0`.
- `secretEnv` (valueFrom `secretKeyRef`) — zero secrete în values, bine.
- Probe `/actuator/health` cu `initialDelaySeconds` realist pentru Spring Boot.
- `resources`: request CPU fără limit CPU (evită throttling), limit doar pe memorie — pattern corect.

---

## Prioritate de acțiune

1. **F1** — șterge `app-data-service.yaml` (bug activ, blochează deploy-ul curat).
2. **F2** — decide sursa secretului MySQL (reflectă `moco-mysql`).
3. **F3** — confirmă `Realm rsk` Synced înainte de test JWT.
4. F4–F7 — curățenie, înainte de a extinde chart-ul pe importer + UI.
