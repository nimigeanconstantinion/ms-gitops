#!/usr/bin/env bash
set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo: sudo $0"
  exit 1
fi

KUBECTL="kubectl"
command -v kubectl >/dev/null 2>&1 || KUBECTL="k3s kubectl"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

used() { df --output=used -k / | tail -1 | tr -d ' '; }
avail() { df -h --output=avail / | tail -1 | tr -d ' '; }
section() { echo; echo "=== $* ==="; }
delta() {
  local before="$1" after
  after=$(used)
  echo "freed: $(( (before - after) / 1024 )) MB   |   now available: $(avail)"
}

section "baseline"
df -h /
du -sh /var/lib/kubelet /var/lib/rancher /var/log 2>/dev/null

section "step 1/4 — delete dead pods"
B=$(used)
$KUBECTL get pods -A --field-selector status.phase=Failed --no-headers 2>/dev/null | wc -l | xargs echo "failed pods:"
$KUBECTL delete pods -A --field-selector status.phase=Failed --ignore-not-found 2>/dev/null
echo "waiting 30s for kubelet volume garbage collection"
sleep 30
delta "$B"

section "step 2/4 — prune unused images"
B=$(used)
k3s crictl rmi --prune >/dev/null 2>&1
delta "$B"

section "step 3/4 — vacuum system logs"
B=$(used)
journalctl --vacuum-time=7d >/dev/null 2>&1
find /var/log -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' 2>/dev/null | xargs -r rm -f
delta "$B"

section "step 4/4 — orphan volume dirs (report only)"
LIVE=$(mktemp)
$KUBECTL get pods -A -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}' 2>/dev/null | sort > "$LIVE"
ORPHAN_TOTAL=0
for d in /var/lib/kubelet/pods/*/; do
  [ -d "$d" ] || continue
  uid=$(basename "$d")
  if ! grep -qx "$uid" "$LIVE"; then
    size_k=$(du -sk "$d" 2>/dev/null | cut -f1)
    ORPHAN_TOTAL=$(( ORPHAN_TOTAL + size_k ))
    echo "ORPHAN $(du -sh "$d" 2>/dev/null | cut -f1)	$d"
  fi
done
rm -f "$LIVE"
echo "orphan total: $(( ORPHAN_TOTAL / 1024 )) MB"
if [ "$ORPHAN_TOTAL" -gt 0 ]; then
  echo "NOT deleted automatically. Review the list above, then remove one by one:"
  echo "  rm -rf /var/lib/kubelet/pods/<UID>"
fi

section "result"
df -h /
du -sh /var/lib/kubelet /var/lib/rancher /var/log 2>/dev/null
$KUBECTL get nodes -o custom-columns='NODE:.metadata.name,DISK_PRESSURE:.status.conditions[?(@.type=="DiskPressure")].status'
