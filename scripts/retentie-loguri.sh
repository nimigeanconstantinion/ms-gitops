#!/usr/bin/env bash
set -uo pipefail

KUBECTL="kubectl"
command -v kubectl >/dev/null 2>&1 || KUBECTL="k3s kubectl"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

RETENTION="${RETENTION:-7d}"
NS="logging"
STS="elasticsearch-es-default"
STREAM="filebeat-8.15.3"

section() { echo; echo "=== $* ==="; }

ES_PW=$($KUBECTL -n "$NS" get secret elasticsearch-es-elastic-user -o go-template='{{.data.elastic | base64decode}}' 2>/dev/null)
if [ -z "${ES_PW:-}" ]; then
  echo "cannot read elasticsearch credentials, aborting"
  exit 1
fi

es() {
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    $KUBECTL -n "$NS" exec "sts/$STS" -c elasticsearch -- \
      curl -sS -k -u "elastic:$ES_PW" -X "$method" "https://localhost:9200$path" \
      -H 'Content-Type: application/json' -d "$body"
  else
    $KUBECTL -n "$NS" exec "sts/$STS" -c elasticsearch -- \
      curl -sS -k -u "elastic:$ES_PW" -X "$method" "https://localhost:9200$path"
  fi
  echo
}

section "before"
df -h /
es GET "/_cat/indices/.ds-filebeat*?v&h=index,docs.count,store.size&s=store.size:desc"

echo
echo "this deletes filebeat log data older than $RETENTION (kept: last $RETENTION only)"
read -r -p "continue? [y/N] " ans
[ "$ans" = "y" ] || { echo "aborted"; exit 0; }

section "1/4 ilm policy with delete phase"
es PUT "/_ilm/policy/filebeat" '{
  "policy": {
    "phases": {
      "hot": {
        "min_age": "0ms",
        "actions": {
          "rollover": { "max_age": "1d", "max_primary_shard_size": "2gb" }
        }
      },
      "delete": {
        "min_age": "'"$RETENTION"'",
        "actions": { "delete": {} }
      }
    }
  }
}'

section "2/4 attach policy to existing backing indices"
es PUT "/$STREAM/_settings" '{"index.lifecycle.name":"filebeat"}'

section "3/4 speed up ilm poll interval"
es PUT "/_cluster/settings" '{"persistent":{"indices.lifecycle.poll_interval":"1m"}}'

section "4/4 force rollover so old indices become deletable"
es POST "/$STREAM/_rollover"

section "waiting for ilm (up to 5 min)"
for i in $(seq 1 10); do
  sleep 30
  echo "--- check $i:"
  df -h / | tail -1
  es GET "/_cat/indices/.ds-filebeat*?h=index,store.size" | sed 's/^/    /'
done

section "after"
df -h /
du -sh /var/lib/rancher/k3s/storage/*elasticsearch* 2>/dev/null
$KUBECTL get nodes -o custom-columns='NODE:.metadata.name,DISK_PRESSURE:.status.conditions[?(@.type=="DiskPressure")].status'
