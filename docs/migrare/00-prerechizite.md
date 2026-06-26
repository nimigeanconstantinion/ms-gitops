# Ghid 0 — Prerechizite (o singură dată, înainte de orice serviciu)

Aceste artefacte sunt cerute de **toate** serviciile. Le faci o dată.

---

## P0.1 — KafkaTopic `product-topic`
**De ce:** serviciile produc/consumă pe `product-topic` (hardcodat în config). În cluster ai doar `orders/events/notifications`.

**Directivă:** creează `infra/kafka/topics/product-topic.yaml`:
```yaml
apiVersion: kafka.strimzi.io/v1
kind: KafkaTopic
metadata:
  name: product-topic
  namespace: messaging
  labels: { strimzi.io/cluster: demo }
spec: { partitions: 3, replicas: 1 }
```
**Verify:** `kubectl -n messaging get kafkatopic product-topic` → Ready · apare în Kafka UI.

---

## P0.2 — Realm `rsk` + client `register-user`
**De ce:** serviciile validează JWT pe realm `rsk` (issuer + jwk-set-uri). Ai doar `demo`. `apps/` (Crossplane) e gol → provider-ul nu produce niciun realm.

**Directivă:** populează `apps/rsk/` cu Realm + Client (Crossplane provider-keycloak):
```yaml
# apps/rsk/realm.yaml
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
    validRedirectUris: ["https://app.icode.mywire.org/*"]
  providerConfigRef: { name: keycloak-provider-config }
```
> Alternativ rapid (dacă Crossplane dă bătăi de cap): un `KeycloakRealmImport` cu `realm-export.json` (îl ai în `ubuntu-microservicii-helm/keycloack/`).

**Verify:** `kubectl get realm,client -A` → Synced · `https://auth.icode.mywire.org/realms/rsk/.well-known/openid-configuration` răspunde.

---

## P0.3 — Secret MySQL pentru ns `business`
**De ce:** serviciile au nevoie de user/parolă pentru clusterul MOCO `mysql` (ns `data`), dar rulează în ns `business`.

**Directivă:** oglindește secretul MOCO `moco-mysql` în `business` via Reflector (adnotări pe sursă) SAU SealedSecret dedicat `mysql-app`. Vezi [`SOLUTIONS.md`](SOLUTIONS.md) §8.

**Verify:** `kubectl -n business get secret mysql-app` → există.

---

## P0.4 — Namespace `business` + Application App-of-Apps
**Directivă:** `argo-apps/app-business.yaml` (wave 5, ns `business`, path `business/`, recurse:true, `CreateNamespace=true`). Vezi pattern în `infra-databases.yaml`.

**Verify:** ArgoCD vede app-ul `business` (gol deocamdată).

---

## P0.5 — Secrete CI (`DOCKERHUB_*`) per repo
**Directivă:** pe fiecare repo serviciu (`importer-service`, `data-service`, `client-microserv-vite`):
```
gh secret set DOCKERHUB_USERNAME -R nimigeanconstantinion/<repo>   # = ion21
gh secret set DOCKERHUB_TOKEN    -R nimigeanconstantinion/<repo>   # token Docker Hub
```
Plus `GITOPS_PAT` (pentru cd-bump) — vezi [`SOLUTIONS.md`](SOLUTIONS.md) §6.

---

## Checklist prerechizite
- [ ] `product-topic` Ready
- [ ] realm `rsk` + client `register-user` Synced
- [ ] secret `mysql-app` în ns `business`
- [ ] Application `business` în ArgoCD
- [ ] secrete CI pe cele 3 repo-uri

➡️ Gata? Treci la [Ghid 1 — data-service](01-data-service.md).
