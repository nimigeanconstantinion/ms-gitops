#!/usr/bin/env bash
# seal-oauth2-proxy.sh — sigileaza SI aplica secretul oauth2-proxy-keycloak.
# Genereaza SealedSecret (pt git/ArgoCD) + il aplica direct (unblock imediat).
# PRECONDITIE: realmul rsk a fost reimportat cu 'secret: BtJSmnt...' (dupa reset-keycloak.sh),
#              altfel client-secret-ul din cluster nu coincide cu Keycloak.
# Ruleaza din radacina repo, in git-bash:  bash scripts/seal-oauth2-proxy.sh
set -uo pipefail
export MSYS_NO_PATHCONV=1

# Ruleaza din radacina repo indiferent de unde e apelat (scriptul e in scripts/)
cd "$(dirname "$0")/.." || { echo "ERROR: nu pot ajunge in radacina repo"; exit 1; }
echo "repo root: $(pwd)"

# client-secret = EXACT valoarea 'secret:' a clientului oauth2-proxy din realm-rsk.yaml
CLIENT_SECRET="${CLIENT_SECRET:-BtJSmntRRePW105y3kM1f3V9kxc/pN6AA8hIw/N8wjA=}"
COOKIE_SECRET="${COOKIE_SECRET:-$(openssl rand -base64 32)}"
CTRL_NS="${CTRL_NS:-kube-system}"
OUT="business/rsk/oauth2-proxy/sealed-secret.yaml"

# Auto-detecteaza numele serviciului controllerului (kubeseal cere --controller-name exact)
CTRL_NAME="${CTRL_NAME:-$(kubectl -n "$CTRL_NS" get svc -l app.kubernetes.io/name=sealed-secrets -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)}"
if [ -z "$CTRL_NAME" ]; then
  CTRL_NAME="$(kubectl -n "$CTRL_NS" get svc -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
fi
[ -z "$CTRL_NAME" ] && { echo "ERROR: nu gasesc serviciul controllerului in ns '$CTRL_NS'. Ruleaza: kubectl -n $CTRL_NS get svc"; exit 1; }

echo "client-secret: ${CLIENT_SECRET:0:10}...  (TREBUIE identic cu 'secret:' din realm-rsk.yaml)"
echo "controller:    svc/$CTRL_NAME in ns $CTRL_NS   ->   output: $OUT"
echo ""

echo "[1/3] Sigilare -> $OUT"
kubectl create secret generic oauth2-proxy-keycloak -n business \
  --from-literal=client-secret="$CLIENT_SECRET" \
  --from-literal=cookie-secret="$COOKIE_SECRET" \
  --dry-run=client -o yaml \
| kubeseal --controller-name "$CTRL_NAME" --controller-namespace "$CTRL_NS" --format yaml > "$OUT"
[ -s "$OUT" ] || { echo "ERROR: sigilarea a esuat (kubeseal / controller ns gresit?)"; exit 1; }
echo "  -> scris $OUT"

echo ""
echo "[2/3] Aplic direct (unblock imediat, fara sa astept commit+ArgoCD)"
kubectl apply -f "$OUT"
echo "  astept ca controllerul sa produca Secret-ul..."
for i in $(seq 1 18); do
  sleep 5
  kubectl -n business get secret oauth2-proxy-keycloak >/dev/null 2>&1 && { echo "  -> Secret oauth2-proxy-keycloak creat"; break; }
  echo "    [$((i*5))s] inca nu..."
done

echo ""
echo "[3/3] Restart oauth2-proxy sa prinda secretul"
kubectl -n business rollout restart deploy/oauth2-proxy 2>/dev/null \
  || kubectl -n business delete pod -l app=oauth2-proxy --ignore-not-found
kubectl -n business rollout status deploy/oauth2-proxy --timeout=120s || true

echo ""
echo "=================================================================="
echo "IMPORTANT: comite ACUM sealed-secret.yaml, altfel ArgoCD (prune:true)"
echo "il sterge la urmatorul sync (nu e in git = orphan)."
echo "  git add $OUT"
echo "  git commit -m 'feat(auth): sealed secret oauth2-proxy-keycloak'"
echo "  git push"
echo "=================================================================="
echo ""
echo "Verificare finala:"
echo "  kubectl -n business get pod -l app=oauth2-proxy"
echo "  curl -sI https://data-service.icode.mywire.org/swagger-ui/   # 302 -> Keycloak login"
