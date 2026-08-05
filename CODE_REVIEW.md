# Code review — ms-gitops (runda 2, 2026-08-05)

> Scope: tot ce s-a adăugat de la runda 1 (2026-07-07) — `business/rsk/**` (Keycloak config-cli, Kong, oauth2-proxy, importer-service), `infra/databases/mysql-init-job.yaml`, `argo-apps/*`, `scripts/*`.
> Stare: `master` @ `bf1562e`.

## Status runda 1

| # | Constatare runda 1 | Status |
|---|---|---|
| F1 | data-service definit de 2 ori | ✅ rezolvat (a păstrat `app-data-service.yaml`, mutat pe ns `business` + `business/rsk/`) |
| F2 | `mysql-app` decuplat de MOCO | ✅ **rezolvat bine** — `infra/databases/mysql-init-job.yaml`, hook de Sync idempotent care face `ALTER USER` din SealedSecret propriu |
| F3 | realm `rsk` nu exista | ✅ rezolvat — `keycloak-config-cli` aplică realm-ul din git, idempotent |
| F6 | docs zic „prin Kong", chart-ul folosea nginx | ✅ acum chiar e prin Kong |
| F7 | comentariu leftover în `root.yaml` | ✅ șters |
| F4 | `syncOptions` inconsistent | ⚠️ invers: acum `ServerSideApply` **nu mai e nicăieri** pe business (vezi M2) |
| F5 | igiena chart-ului `microservice` | ⏳ neschimbat, dar acum îl folosesc 2 servicii (vezi M5) |

`mysql-init-job.yaml` merită subliniat: ai transformat o problemă de „secret static vs parolă rotativă" într-un job care **reconciliază** starea (`CREATE USER IF NOT EXISTS` + `ALTER USER`) la fiecare sync. Asta e diferența dintre a configura și a reconcilia — jobul supraviețuiește recreării clusterului fără intervenție manuală. Exact ce trebuie.

---

## 🔴 Critice

### G1 — Client secret Keycloak în clar, într-un repo PUBLIC

`business/rsk/keycloak/realm/rsk.yaml:86`
```yaml
  - clientId: oauth2-proxy
    publicClient: false
    clientAuthenticatorType: "client-secret"
    secret: "BtJSmn…"        # valoarea completă e în fișier — de rotit
```

Aceeași valoare, a doua oară: `scripts/fix-oauth2-proxy.sh:16`
```bash
CLIENT_SECRET="${CLIENT_SECRET:-BtJSmn…}"
```

(în review am trunchiat-o intenționat — documentul ăsta ajunge tot într-un repo public)

Verificat acum:
```
$ gh repo view nimigeanconstantinion/ms-gitops --json visibility
{"isPrivate":false,"visibility":"PUBLIC"}
```

Și — partea care doare — **aceeași valoare e sigilată corect** în `business/rsk/oauth2-proxy/sealed-secret.yaml:9`. Adică ai făcut efortul de a cripta un secret pe care îl ții în clar în același repo, la două fișiere distanță. SealedSecret-ul nu mai protejează nimic: cine are repo-ul are secretul, indiferent cât de bine e criptat blob-ul de lângă.

Comentariul din realm (`:84-85`, „Secret EXPLICIT (determinist) — aceeași valoare e în SealedSecret") arată de ce s-a ajuns aici: aveai nevoie ca cele două să coincidă, iar cea mai simplă cale de a garanta asta a fost să scrii valoarea în ambele locuri. Constrângerea e reală. Soluția nu e.

**Impact onest:** singur, secretul nu îți dă acces — clientul e pe authorization code flow, cu `directAccessGrantsEnabled: false`, deci fără login de user nu se obține token. Dar e un credențial de client confidențial publicat pe internet, iar poarta de auth a întregii platforme atârnă de el. Se rotește, nu se discută.

**Fix (păstrează determinismul, fără valoare în git):** `keycloak-config-cli` știe substituție de variabile.

```yaml
# job-config-cli.yaml — env nou pe container:
- name: IMPORT_VAR_SUBSTITUTION_ENABLED
  value: "true"
- name: OAUTH2_PROXY_CLIENT_SECRET
  valueFrom:
    secretKeyRef: { name: oauth2-proxy-keycloak, key: client-secret }
```
```yaml
# realm/rsk.yaml:
    secret: "$(env:OAUTH2_PROXY_CLIENT_SECRET)"
```

Sursa unică devine SealedSecret-ul; realm-ul și oauth2-proxy citesc **aceeași** valoare, iar git-ul nu o vede niciodată. Secret-ul trebuie reflectat/prezent în ns `auth` pentru Job (adnotări Reflector, ca la `external-db`).

**Ordinea operațiunilor (contează):**
1. generezi secret nou: `openssl rand -base64 32`
2. resigilezi `oauth2-proxy-keycloak` cu el
3. schimbi realm-ul pe `$(env:...)` și ștergi valoarea din `fix-oauth2-proxy.sh`
4. commit + sync → config-cli actualizează clientul, oauth2-proxy repornește cu noul secret
5. **abia apoi** te gândești dacă repo-ul trebuie să rămână public — rotația e obligatorie oricum, istoricul git păstrează valoarea veche

---

## Before / After (critice)

| # | Acum | Cum ar trebui |
|---|---|---|
| G1 | `realm/rsk.yaml:86`<br>`secret: "BtJSmn…"` (valoare în clar) | `secret: "$(env:OAUTH2_PROXY_CLIENT_SECRET)"`<br>+ `IMPORT_VAR_SUBSTITUTION_ENABLED: "true"` și `secretKeyRef` pe Job |
| G1 | `scripts/fix-oauth2-proxy.sh:16`<br>`CLIENT_SECRET="${CLIENT_SECRET:-BtJSmn…}"` | `CLIENT_SECRET="${CLIENT_SECRET:?seteaza CLIENT_SECRET in shell, nu in fisier}"` |

---

## 🟡 Importante

**M1 — Kong nu recitește `kong.yml`; modificările de rutare se aplică tăcut „niciodată".**
`business/rsk/kong/declarative/kustomization.yaml:11-12` — `disableNameSuffixHash: true`, iar `kong/values.yaml:9-10` referă ConfigMap-ul pe nume fix (`kong-declarative`). Când schimbi `kong.yml`: ConfigMap-ul se actualizează în cluster, ArgoCD arată `Synced`, fișierul montat în pod se împrospătează în ~60s — dar **Kong în modul dbless citește configul declarativ doar la pornire**. Pod-ul rulează mai departe cu rutele vechi. Nimic nu e roșu nicăieri.

Hash-ul dezactivat e obligatoriu aici (numele trebuie să fie fix, ca `dblessConfig.configMap` să-l găsească), deci soluția nu e să-l reactivezi, ci să dai un motiv Deployment-ului să facă rollout: `podAnnotations` cu o valoare care se schimbă odată cu configul (`kong-config-rev: "<data/SHA>"` — asta e și în PENDING-urile tale). Regula generală: *un ConfigMap montat nu repornește nimic; doar o schimbare în pod template face rollout.*

**M2 — `ServerSideApply` a dispărut de pe tot stratul business.**
Îl are doar `argo-apps/app-rsk-keycloak.yaml:30`. `app-data-service.yaml`, `app-importer-service.yaml`, `app-kong.yaml`, `app-oauth2-proxy.yaml` — niciunul. La runda 1 recomandarea era să-l păstrezi; a plecat odată cu fișierul șters. Nu te doare azi (manifeste mici), dar la primul CR mare sau la un `last-applied-configuration` peste 262KB primești `metadata.annotations: Too long` la sync, iar cauza e greu de legat de ce ai schimbat. Aliniază-le pe toate.

**M3 — hook-ul de realm iese pe internet ca să ajungă la un serviciu din cluster.**
`business/rsk/keycloak/job-config-cli.yaml:21-22` — `KEYCLOAK_URL: https://auth.icode.mywire.org`. Jobul rulează în ns `auth`, la câțiva metri de Keycloak, dar trece prin: DNS public → Cloudflare/router → nginx ingress → cert TLS → înapoi în cluster (hairpin). Fiecare verigă e un mod nou de a eșua. Și pentru că e `argocd.argoproj.io/hook: Sync`, dacă jobul cade, **sync-ul aplicației `rsk-keycloak` nu se finalizează** — deci o problemă de DNS extern îți blochează configurarea realm-ului. Folosește Service-ul intern (`http://keycloak-service.auth.svc:8080`); issuer-ul din realm rămâne cel public — config-cli doar administrează, nu emite tokenuri.

**M4 — automatizarea permanentă folosește credențialul de bootstrap.**
`job-config-cli.yaml:26,31` — `keycloak-initial-admin`, secretul generat de operator la prima pornire. E gândit ca „intră o dată și fă-ți cont normal", nu ca identitate de serviciu. Dacă e rotit sau șters, config-cli moare la următorul sync și realm-ul îngheață. Corect: un client cu service account în realm `master`, cu rolurile `manage-realm` + `manage-clients` doar pe realm-ul `rsk`.

**M5 — chart-ul `microservice` a rămas la nivelul de la runda 1, dar acum îl folosesc 2 servicii (și urmează UI-ul).**
`business/charts/microservice/templates/ingress.yaml:13-14` — `host` și `tlsSecretName` fără guard; cu `ingress.enabled: true` și câmpurile goale (default în `values.yaml:32-33`) generezi un Ingress invalid, iar eroarea apare la sync, nu la scriere. Lipsesc `_helpers.tpl` și label-urile `app.kubernetes.io/*` — la 3 servicii deja simți lipsa lor în Prometheus/Kibana, unde nu poți selecta „toate serviciile business" fără să le enumeri.

**M6 — realm `demo` leftover, aplicat activ.**
`infra/keycloak/realm-demo.yaml` e în `path: infra/keycloak` (`argo-apps/infra-keycloak.yaml:16`) → se aplică un `KeycloakRealmImport` numit `demo-realm` care creează realm-ul `demo`, în paralel cu `rsk`. Plus o copie moartă a aceluiași fișier în `apps/realm.yaml` (folderul `apps/` nu e referit de nimeni — `root.yaml` recursează doar `argo-apps/`). Exact tipul de resursă create-only care ți-a dat bătăi de cap și pe care ai eliminat-o corect pentru `rsk`. Șterge-le pe amândouă.

---

## 🟢 Cleanups

- **C1** — `scripts/fix-oauth2-proxy.sh` face `kubeseal` + `kubectl apply` + `rollout restart` direct în cluster. Ca reparație one-shot e ok, dar cu `selfHeal: true` pe toate app-urile, orice `apply` manual e revenit de ArgoCD în secunde — iar dacă *nu* e (pentru că resursa nu e în git), ai creat drift invizibil. Pune în antet, cu majuscule: „scrie în git după, altfel se pierde".
- **C2** — Ingress-urile de gateway ale serviciilor (`business/rsk/kong/ingress/data-service-gateway.yaml`, `importer-service-gateway.yaml`) trăiesc în Application-ul `kong` (`app-kong.yaml:26-32`), nu în cel al serviciului. Consecință: ștergi app-ul `kong` → dispar rutele externe ale serviciilor; adaugi un serviciu nou → editezi în două app-uri. Ingress-ul e parte din serviciu, nu din gateway.
- **C3** — dependență implicită nedocumentată: `oauth2-proxy/deployment.yaml:26` are `--redirect-url` fix pe host-ul data-service, dar fluxul funcționează și pentru `importer-service.icode.mywire.org` **doar** datorită `--cookie-domain=.icode.mywire.org` + `--whitelist-domain` (`:36-37`). Merge, e corect — dar cine adaugă mâine un host din alt domeniu va căuta ore întregi de ce primește `Invalid parameter: redirect_uri`. Două linii de comentariu.
- **C4** — `infra/databases/mysql-init-job.yaml:38-43`: heredoc `<<SQL` neescapat — o parolă care conține `$` sau `` ` `` e interpretată de bash înainte să ajungă la MySQL. Folosește `<<'SQL'` + variabile de mediu MySQL, sau escapează. Și `GRANT ALL PRIVILEGES` e mai mult decât are nevoie un serviciu care face CRUD pe `micro_db` — nu-i trebuie `DROP`/`GRANT OPTION`.
- **C5** — `docs/migrare/02-importer-service.md` descrie starea de dinaintea migrării; acum importer-ul e live. Un rând de „STARE: migrat, vezi values" în capul fișierului evită să lucrezi după o hartă veche.

---

## Q&A

**Q1.** Ai criptat corect `client-secret` în SealedSecret și ai scris aceeași valoare în clar în realm, ca să coincidă. Care e mecanismul prin care poți garanta că cele două coincid **fără** ca valoarea să existe în git? (indiciu: cine citește fișierul de realm și cu ce permisiuni rulează)

**Q2.** Schimbi o rută în `kong.yml`, comiți, ArgoCD zice `Synced` și `Healthy`. De ce ruta nouă tot nu răspunde, și ce anume — concret, la nivel de obiect Kubernetes — trebuie să se schimbe ca pod-ul să se recreeze?

**Q3.** `job-config-cli` e `hook: Sync`. Ce se întâmplă cu Application-ul `rsk-keycloak` dacă jobul eșuează de 3 ori (`backoffLimit: 2`)? Și de ce contează asta când `KEYCLOAK_URL` e un hostname public, nu un Service intern?
