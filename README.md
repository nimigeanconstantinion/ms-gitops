# ms-gitops — Platformă GitOps (car-platform)

Platformă **GitOps** pe K3s, gestionată cu **ArgoCD (App-of-Apps)**. Tot ce rulează în cluster e definit aici; `git push` = singura modalitate de a schimba clusterul.

- **Domeniu:** `icode.mywire.org` (Dynu DDNS) · **Server:** server2
- **Infra:** prin operatori (Strimzi, MOCO, CNPG, Keycloak, ECK, Crossplane)

---

## 🚦 Unde suntem acum
| Strat | Status |
|---|---|
| Infra (edge, observability, logging, messaging, data, auth) | ✅ funcțional |
| **Business layer** (microservicii importer/data/UI) | ⬜ **de migrat** → vezi `docs/migrare/` |

> Detaliu status infra + ce mai e de finisat: **[`NEXT_STEPS.md`](NEXT_STEPS.md)**.

---

## 📁 Structura repo-ului — unde e ce
| Folder | Ce conține | Când îl atingi |
|---|---|---|
| **`bootstrap/`** | `root.yaml` — App-of-Apps (kickoff manual, o dată) | la instalare |
| **`argo-apps/`** | definițiile `Application` (o per componentă) | când adaugi un serviciu/operator |
| **`infra/`** | manifeste + `values.yaml` pt operatori și CR-uri (kafka, databases, keycloak, eck…) | când configurezi infra |
| **`apps/`** | realms/clients Keycloak declarativi (Crossplane) | când adaugi auth |
| **`business/`** | *(de creat)* microserviciile business (importer/data/UI) | la migrarea aplicațiilor |
| **`docs/`** | 📚 **documentația — ÎNCEPE AICI** | mereu |
| **`scripts/`** | install / wipe / kubeconfig | la setup server |

---

## 🧭 De unde începi (ghid pentru tine)

**1. Înțelegi sistemul** → [`docs/diagrame/`](docs/diagrame/)
- `architecture-final.pdf` — infra (operatori, namespace-uri, waves)
- `services-communication.pdf` — cum comunică microserviciile

**2. Vezi ce mai e de făcut pe infra** → [`NEXT_STEPS.md`](NEXT_STEPS.md)

**3. Migrezi business-ul (microserviciile)** → [`docs/migrare/`](docs/migrare/README.md)
- Urmează în ordine: `00-prerechizite` → `01-data-service` → `02-importer-service` → `03-client-ui`
- Fiecare ghid are: analiză, directive pas-cu-pas, **Definition of Done**
- Pentru cod/config exact: [`docs/migrare/SOLUTIONS.md`](docs/migrare/SOLUTIONS.md)

---`

## 🗺️ Harta documentației
```
docs/
├── README.md                  ← index documentație
├── diagrame/                  ← scheme vizuale (infra + servicii)
└── migrare/                   ← migrarea business, serviciu cu serviciu
    ├── README.md              ← ordine + reguli + DoD
    ├── MIGRATION_PLAN.md      ← strategia
    ├── BACKLOG.md             ← epics + stories
    ├── SOLUTIONS.md           ← cod/config concret
    └── 00…03                  ← ghiduri de execuție
```

## ⚙️ Cum funcționează (pe scurt)
```
git push → ArgoCD vede commit-ul → root scanează argo-apps/ → sync per wave → cluster
```
`prune: true` + `selfHeal: true` — orice modificare manuală în cluster e corectată din git.

---

👉 **Următorul pas:** deschide [`docs/migrare/README.md`](docs/migrare/README.md) și începe cu prerechizitele.
