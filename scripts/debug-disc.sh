#!/usr/bin/env bash
set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run with sudo: sudo $0"
  exit 1
fi

KUBECTL="kubectl"
command -v kubectl >/dev/null 2>&1 || KUBECTL="k3s kubectl"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

section() { echo; echo "=============================================="; echo "$*"; echo "=============================================="; }

section "1. filesystems and physical disks"
df -h -x tmpfs -x devtmpfs -x squashfs
echo
lsblk -d -o NAME,SIZE,MODEL

section "2. top-level usage on / (single filesystem, no bind mounts)"
du -shx /* 2>/dev/null | sort -h | tail -12

section "3. /var/lib breakdown"
du -shx /var/lib/* 2>/dev/null | sort -h | tail -10

section "4. kubelet: real data vs bind-mounted PVCs"
echo "--- pods dir INCLUDING bind mounts (inflated):"
du -sh /var/lib/kubelet/pods 2>/dev/null
echo "--- pods dir EXCLUDING bind-mounted volumes (real local usage):"
du -sh --exclude='*kubernetes.io~local-volume*' --exclude='*volume-subpaths*' /var/lib/kubelet/pods 2>/dev/null
echo "--- other kubelet subdirs:"
du -shx /var/lib/kubelet/* 2>/dev/null | grep -v '/pods$' | sort -h | tail -5

section "5. k3s local-path storage, per volume"
du -sh /var/lib/rancher/k3s/storage/* 2>/dev/null | sort -h | tail -15

section "6. PVC requested vs actually used on disk"
printf "%-14s %-34s %-10s %-10s %s\n" "NAMESPACE" "PVC" "REQUESTED" "REAL" "PATH"
$KUBECTL get pv -o jsonpath='{range .items[*]}{.spec.claimRef.namespace}{"|"}{.spec.claimRef.name}{"|"}{.spec.capacity.storage}{"|"}{.spec.local.path}{"|"}{.spec.hostPath.path}{"\n"}{end}' 2>/dev/null |
while IFS='|' read -r ns pvc cap lpath hpath; do
  path="${lpath:-$hpath}"
  [ -n "$path" ] || continue
  real=$(du -sh "$path" 2>/dev/null | cut -f1)
  printf "%-14s %-34s %-10s %-10s %s\n" "$ns" "$pvc" "$cap" "${real:-?}" "$path"
done

section "7. container logs"
du -sh /var/log/pods /var/log/containers /var/log/journal 2>/dev/null
echo "--- 10 largest container log files:"
find /var/log/pods -name '*.log' -type f -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -10 | awk '{printf "%.0f MB\t%s\n", $1/1024/1024, $2}'

section "8. containerd images"
du -sh /var/lib/rancher/k3s/agent/containerd 2>/dev/null
k3s crictl images 2>/dev/null | wc -l | xargs echo "images:"

section "9. largest files on / (over 1G)"
find / -xdev -type f -size +1G -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -15 | awk '{printf "%.1f GB\t%s\n", $1/1024/1024/1024, $2}'

section "10. elasticsearch indices"
ES_PW=$($KUBECTL -n logging get secret elasticsearch-es-elastic-user -o go-template='{{.data.elastic | base64decode}}' 2>/dev/null)
if [ -n "${ES_PW:-}" ]; then
  $KUBECTL -n logging exec sts/elasticsearch-es-default -c elasticsearch -- \
    curl -sS -k -u "elastic:$ES_PW" "https://localhost:9200/_cat/indices?v&h=index,docs.count,store.size&s=store.size:desc" 2>/dev/null | head -15
  echo "--- ilm policy filebeat (delete phase present?):"
  $KUBECTL -n logging exec sts/elasticsearch-es-default -c elasticsearch -- \
    curl -sS -k -u "elastic:$ES_PW" "https://localhost:9200/_ilm/policy/filebeat" 2>/dev/null | grep -o '"delete"' | head -1 || echo "NO DELETE PHASE"
else
  echo "elasticsearch secret not readable, skipping"
fi

section "done"
echo "nothing was deleted or modified by this script"
