#!/usr/bin/env bash
# fix-oauth2-proxy.sh — repara oauth2-proxy: cookie-secret valid (32 bytes) + sigilare + aplicare + restart.
# Rezolva crash-ul: "cookie_secret must be 16, 24, or 32 bytes".
# PRECONDITIE: realmul rsk reimportat cu 'secret: BtJSmnt...' (dupa reset-keycloak.sh).
# Ruleaza de oriunde in repo, git-bash:  bash scripts/fix-oauth2-proxy.sh
set -uo pipefail
export MSYS_NO_PATHCONV=1

# Radacina repo (robust, prin git)
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$ROOT" ] && ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || { echo "ERROR: nu pot ajunge in radacina repo"; exit 1; }
echo "repo root: $(pwd)"

# client-secret = EXACT valoarea 'secret:' a clientului oauth2-proxy din realm-rsk.yaml
CLIENT_SECRET="${CLIENT_SECRET:-BtJSmntRRePW105y3kM1f3V9kxc/pN6AA8hIw/N8wjA=}"
# cookie-secret: 32 caractere = 32 bytes (oauth2-proxy accepta doar 16/24/32)
COOKIE_SECRET="${COOKIE_SECRET:-$(openssl rand -hex 16)}"
OUT="business/rsk/oauth2-proxy/sealed-secret.yaml"

echo "cookie-secret length: ${#COOKIE_SECRET} (trebuie 32)"
[ "${#COOKIE_SECRET}" = "32" ] || { echo "ERROR: cookie-secret nu e 32 bytes"; exit 1; }

# Gaseste controllerul sealed-secrets oriunde e (default kubeseal: kube-system/sealed-secrets-controller)
found="$(kubectl get svc -A -l app.kubernetes.io/name=sealed-secrets -o jsonpath='{.items[0].metadata.namespace} {.items[0].metadata.name}' 2>/dev/null)"
CTRL_NS="${CTRL_NS:-${found%% *}}"; CTRL_NS="${CTRL_NS:-kube-system}"
CTRL_NAME="${CTRL_NAME:-${found##* }}"; CTRL_NAME="${CTRL_NAME:-sealed-secrets-controller}"
echo "controller: svc/$CTRL_NAME in ns $CTRL_NS"

echo ""
echo "[1/4] Sigilare -> $OUT"
kubectl create secret generic oauth2-proxy-keycloak -n business \
  --from-literal=client-secret="$CLIENT_SECRET" \
  --from-literal=cookie-secret="$COOKIE_SECRET" \
  --dry-run=client -o yaml \
| kubeseal --controller-name "$CTRL_NAME" --controller-namespace "$CTRL_NS" --format yaml > "$OUT"
[ -s "$OUT" ] || { echo "ERROR: sigilarea a esuat"; exit 1; }
echo "  -> scris $OUT"

echo ""
echo "[2/4] Aplic SealedSecret"
kubectl apply -f "$OUT"
for i in $(seq 1 18); do
  sleep 5
  kubectl -n business get secret oauth2-proxy-keycloak >/dev/null 2>&1 && { echo "  -> Secret oauth2-proxy-keycloak (re)creat"; break; }
done

echo ""
echo "[3/4] Restart oauth2-proxy"
kubectl -n business rollout restart deploy/oauth2-proxy
kubectl -n business rollout status deploy/oauth2-proxy --timeout=120s || true

echo ""
echo "[4/4] Stare + test"
kubectl -n business get pod -l app=oauth2-proxy
code="$(curl -sI -o /dev/null -w '%{http_code}' https://data-service.icode.mywire.org/swagger-ui/ 2>/dev/null || echo '???')"
echo "  curl /swagger-ui/ -> HTTP $code   (302 = OK; 500/403 = client-secret != Keycloak, reimporta realmul)"

echo ""
echo "Daca e Running, COMITE (altfel ArgoCD prune il sterge):"
echo "  git add $OUT && git commit -m 'feat(auth): sealed secret oauth2-proxy-keycloak' && git push"
