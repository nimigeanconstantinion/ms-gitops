# Ghid 3 — Migrare `client / UI`

> Ghid de îndrumare. **Tu** execuți. UI cere **runtime config** (Vite injectează la build-time).
> Premisă: [Ghid 1](01-data-service.md) + [Ghid 2](02-importer-service.md) live (API-urile răspund prin Kong).

## Sumar serviciu
| | |
|---|---|
| Repo / imagine | `client-microserv-vite` → `ion21/client-service` |
| Port | `3000` (Node 22) · branch `feat/keycloak-vite` |
| Rol | UI React/Vite — login Keycloak, cheamă `/api/v1/query` + `/api/v1/command` prin Kong |
| Dependențe | API-urile (importer/data) prin Kong, Keycloak (realm `rsk`) |

## Analiză stare curentă
| Aspect | Stare | Acțiune |
|---|---|---|
| Config | `.env` cu `VITE_*` **build-time** | → runtime config |
| Loader runtime | ✅ `Api.tsx` deja face `fetch(configPath)` | finalizează pe `app-config.json` |
| `.env` tracked în git | ⚠️ risc leak | scoate din git |
| CI trigger | ✅ `master` + `feat/**` | branch-ul NU e blocaj |

---

## Directive (pas cu pas)

### 1. Finalizează runtime config (fără rebuild per mediu)  `P0`
Vite bake-uiește `VITE_*` la build → o imagine = un mediu. Treci pe config citit la **runtime** (codul deja are `fetch(configPath)`).

**a)** `public/app-config.json` (default dev):
```json
{ "API_URL": "http://localhost:5000", "KEYCLOAK_URL": "http://localhost:8085", "REALM": "rsk", "CLIENT_ID": "register-user" }
```
**b)** asigură-te că appul citește din fișierul ăsta (nu din `import.meta.env.VITE_*`). Vezi [`SOLUTIONS.md`](SOLUTIONS.md) §5.
**c)** Dockerfile copiază `app-config.json` în imagine; în cluster îl **suprascrii cu ConfigMap** → un singur build, orice mediu.

### 2. Scoate `.env` din git  `P0`
```bash
git rm --cached .env
echo ".env" >> .gitignore
git commit -m "chore: untrack .env"
```

### 3. Testează local  `P0`
```bash
# .env.local (NEgit) cu backend local
npm ci
npm run dev                  # dev server, hot-reload, pointat la API local
npm run build && npm run preview   # verifică build-ul de producție
```

### 4. Pipeline CI/CD  `P0`
Pipeline din [`SOLUTIONS.md`](SOLUTIONS.md) §1 adaptat pentru Node: jobul `build-test` = `npm ci && npm run lint && npm run build` (+ `type-check`); publish `ion21/client-service:<sha>`; cd-bump în gitops. Rulează pe `master` + `feat/**`.

### 5. Manifest GitOps + Ingress + ConfigMap  `P0`
În `business/`:
- `client.yaml` — Deployment (port 3000) + Service
- `client-config.yaml` — ConfigMap `app-config.json` montat peste `/usr/share/nginx/html/app-config.json`:
  ```json
  { "API_URL": "https://app.icode.mywire.org/api", "KEYCLOAK_URL": "https://auth.icode.mywire.org", "REALM": "rsk", "CLIENT_ID": "register-user" }
  ```
- `client-ingress.yaml` — Ingress `app.icode.mywire.org` (TLS via cert-manager, ssl-redirect)

### 6. Deploy + verify  `P0`
```bash
kubectl -n business get pods                 # client Running
```
- Deschide `https://app.icode.mywire.org` → **login Keycloak** (realm `rsk`) → afișează produsele (din data-service prin Kong).
- Verifică în Network tab că `app-config.json` are URL-urile cluster (nu localhost).

---

## Gotchas specifice
- **Vite = build-time** pentru `VITE_*`. Dacă lași `.env` cu `localhost`, imaginea built ar pointa la localhost în cluster → folosește runtime config (pasul 1).
- Keycloak client `register-user` trebuie să aibă `app.icode.mywire.org/*` în **Valid Redirect URIs** (altfel login-ul eșuează) — vezi Ghid 0.
- CORS: backend-urile trebuie să accepte originea `https://app.icode.mywire.org` (`app.cors.allowed-origins`).

## Definition of Done
- [ ] runtime config (`app-config.json`) · [ ] `.env` scos din git · [ ] rulează local
- [ ] CI verde · [ ] `business/client.yaml` + ConfigMap + Ingress
- [ ] ArgoCD Synced+Healthy · [ ] UI live, login `rsk` OK, afișează produse

🎉 Cele 3 servicii migrate → layer business complet în GitOps.
