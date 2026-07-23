#!/usr/bin/env bash
# debug-auth.sh — diagnostic READ-ONLY pentru lantul auth al ms-gitops
# Keycloak -> realm rsk -> oauth2-proxy -> kong -> data-service
# Nu modifica nimic (doar get/describe/curl intern). Ruleaza: bash scripts/debug-auth.sh
set +e
export MSYS_NO_PATHCONV=1   # git-bash: nu converti path-urile /... in C:\...

line() { printf '\n========== %s ==========\n' "$1"; }
sub()  { printf '\n--- %s ---\n' "$1"; }

line "0. CLUSTER: ce e picat (fara Running/Completed)"
kubectl get pods -A | grep -Ev "Running|Completed" || echo "  (tot e Running/Completed)"

line "1. AUTH namespace"
sub "pods"
kubectl -n auth get pod -o wide
sub "keycloak CR"
kubectl -n auth get keycloak -o wide
sub "keycloakrealmimport (create-only! status conteaza)"
kubectl -n auth get keycloakrealmimport
kubectl -n auth get keycloakrealmimport -o jsonpath='{range .items[*]}{.metadata.name}{"  Done="}{.status.conditions[?(@.type=="Done")].status}{"  Msg="}{.status.conditions[?(@.type=="Done")].message}{"\n"}{end}'
sub "secret keycloak-initial-admin (existenta + username; NU printez parola)"
kubectl -n auth get secret keycloak-initial-admin >/dev/null 2>&1 \
  && echo "  exista. username = $(kubectl -n auth get secret keycloak-initial-admin -o jsonpath='{.data.username}' | base64 -d)" \
  || echo "  LIPSESTE"

line "2. KEYCLOAK live (din interiorul clusterului, prin pod)"
KCPOD=$(kubectl -n auth get pod -l app=keycloak -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -z "$KCPOD" ] && KCPOD=keycloak-0
echo "  pod folosit: $KCPOD"
sub "health"
kubectl -n auth exec "$KCPOD" -- curl -sS -o /dev/null -w "  master health http=%{http_code}\n" http://localhost:9000/health/ready 2>/dev/null \
  || echo "  nu pot exec/curl in pod"
sub "realm rsk reachable (JWKS)"
kubectl -n auth exec "$KCPOD" -- curl -sS -o /dev/null -w "  realms/rsk/certs http=%{http_code}\n" http://localhost:8080/realms/rsk/protocol/openid-connect/certs 2>/dev/null

line "3. BUSINESS namespace"
sub "pods"
kubectl -n business get pod -o wide
sub "oauth2-proxy: exista secretul? (asta e cauza CreateContainerConfigError)"
kubectl -n business get sealedsecret,secret 2>/dev/null | grep -i oauth2 || echo "  NICIUN secret/sealedsecret oauth2 -> ASTA e problema"
sub "oauth2-proxy pod events"
OPOD=$(kubectl -n business get pod -l app=oauth2-proxy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$OPOD" ] && kubectl -n business describe pod "$OPOD" | sed -n '/Events/,$p' || echo "  nu exista pod oauth2-proxy"
sub "kong + data-service pods (status/restarts)"
kubectl -n business get pod -l app.kubernetes.io/name=kong 2>/dev/null
kubectl -n business get pod | grep -E "kong|data-service" || true

line "4. SEALED-SECRETS controller (daca e picat, niciun secret nu se decripteaza)"
kubectl -n sealed-secrets get pod 2>/dev/null || kubectl get pod -A | grep -i sealed

line "5. INGRESS-uri business (host-uri + TLS)"
kubectl -n business get ingress -o wide

line "6. ARGOCD: ce app-uri nu-s Synced/Healthy"
kubectl -n argocd get applications.argoproj.io 2>/dev/null \
  -o custom-columns="APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status" \
  | grep -Ev "Synced.*Healthy" || echo "  toate Synced+Healthy (sau nu am acces la CRD-ul Application)"

line "GATA"
echo "Trimite tot output-ul de mai sus."
