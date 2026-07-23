#!/usr/bin/env bash
# reset-keycloak.sh — RESET COMPLET Keycloak: DB proaspata + admin nou + realm reimportat.
# DISTRUCTIV: sterge realmul rsk, userii, clientii si adminul din Keycloak.
# Realmul rsk REVINE din git (realm-rsk.yaml) la re-import, cu noul secret oauth2-proxy.
# NU atinge alte DB-uri (mysql/mongo/car). Ruleaza in git-bash:  bash scripts/reset-keycloak.sh
set -uo pipefail
export MSYS_NO_PATHCONV=1   # git-bash: nu converti path-urile /...

echo "=================================================================="
echo " RESET COMPLET KEYCLOAK"
echo " Sterge DB-ul 'keycloak' (realm rsk, useri, clienti, admin)."
echo " Realmul revine din git la re-import. Alte servicii NU sunt atinse."
echo "=================================================================="
read -r -p "Scrie exact  RESET  ca sa continui: " ans
[ "$ans" = "RESET" ] || { echo "Anulat."; exit 1; }

PGPOD=$(kubectl -n data get pod -l cnpg.io/cluster=postgres-keycloak -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -z "$PGPOD" ] && { echo "ERROR: nu gasesc pod-ul postgres-keycloak in ns data"; exit 1; }
echo "Postgres pod: $PGPOD"

echo ""
echo "[1/4] Drop + recreate database 'keycloak' (fresh)"
kubectl -n data exec "$PGPOD" -- psql -U postgres -d postgres -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='keycloak' AND pid<>pg_backend_pid();" || true
kubectl -n data exec "$PGPOD" -- psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS keycloak;"
kubectl -n data exec "$PGPOD" -- psql -U postgres -d postgres -c "CREATE DATABASE keycloak OWNER keycloak;"
echo "  -> DB keycloak goala, owner keycloak"

echo ""
echo "[2/4] Restart Keycloak (re-init schema + bootstrap admin nou pe DB goala)"
kubectl -n auth delete pod keycloak-0 --ignore-not-found
echo "  astept sa fie Ready (max 5 min)..."
kubectl -n auth rollout status statefulset/keycloak --timeout=300s \
  || kubectl -n auth wait --for=condition=ready pod/keycloak-0 --timeout=300s || true

echo ""
echo "[3/4] Force re-import realm (KeycloakRealmImport e create-only)"
kubectl -n auth delete keycloakrealmimport --all --ignore-not-found
echo "  ArgoCD le recreeaza din git in ~1-3 min (sau forteaza sync pe app-rsk-keycloak)."
echo "  astept ca rsk-realm sa fie Done=True..."
for i in $(seq 1 36); do
  sleep 10
  st=$(kubectl -n auth get keycloakrealmimport rsk-realm -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || true)
  echo "    [$((i*10))s] rsk-realm Done=${st:-<inca-nu-exista>}"
  [ "$st" = "True" ] && break
done

echo ""
echo "[4/4] GATA. Admin proaspat (login pe https://auth.icode.mywire.org/admin/master/console/):"
echo "  user: $(kubectl -n auth get secret keycloak-initial-admin -o jsonpath='{.data.username}' | base64 -d)"
echo "  pass: $(kubectl -n auth get secret keycloak-initial-admin -o jsonpath='{.data.password}' | base64 -d)"
echo ""
echo "URMEAZA (manual) — sigileaza secretul oauth2-proxy cu valoarea din realm si commit:"
cat <<'EOF'
  kubectl create secret generic oauth2-proxy-keycloak -n business \
    --from-literal=client-secret='BtJSmntRRePW105y3kM1f3V9kxc/pN6AA8hIw/N8wjA=' \
    --from-literal=cookie-secret="$(openssl rand -base64 32)" \
    --dry-run=client -o yaml \
  | kubeseal --controller-namespace sealed-secrets --format yaml \
    > business/rsk/oauth2-proxy/sealed-secret.yaml
  # commit sealed-secret.yaml -> App recurse:true il ia singur -> oauth2-proxy porneste
EOF
echo ""
echo "Verificare finala:"
echo "  kubectl -n business get pod -l app=oauth2-proxy"
echo "  curl -sI https://data-service.icode.mywire.org/swagger-ui/   # 302 -> Keycloak"
