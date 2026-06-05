# sealed-secrets

Controller care decriptează `SealedSecret` din git → `Secret` normal în cluster.

| | |
|---|---|
| Application | `argo-apps/infra-sealed-secrets.yaml` |
| Chart | `bitnami-labs/sealed-secrets` v2.16.2 |
| Namespace | `kube-system` |
| Release name | `sealed-secrets-controller` (necesar pentru `kubeseal` CLI default) |

## Verify

```bash
kubectl -n kube-system get pods | grep sealed-secrets
kubectl -n kube-system logs deploy/sealed-secrets-controller --tail=20
```

## Workflow

```bash
# 1. Creează Secret normal local (NU commit!)
cat > /tmp/foo-secret-raw.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: foo
  namespace: bar
stringData:
  password: "real-password"
EOF

# 2. Sigilează cu kubeseal
kubeseal --controller-namespace kube-system \
         --controller-name sealed-secrets-controller \
         --format yaml \
         < /tmp/foo-secret-raw.yaml \
         > infra/<componenta>/foo-sealed.yaml

# 3. Commit fișierul sigilat (safe în git)
git add infra/<componenta>/foo-sealed.yaml

# 4. Cleanup
rm /tmp/foo-secret-raw.yaml
```

## Edit hint

- `replicaCount: 1` — pentru HA pune 3 cu PDB
- `metrics.serviceMonitor.enabled: false` — activează DUPĂ ce ai Prometheus (kube-prometheus-stack)

## Capcane

- **`SealedSecret` nu se decriptează** după restore cluster → cheia controller-ului s-a schimbat. Backup `kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml` OFFLINE
- Sealed cu nume/namespace greșit → re-sealează cu `--namespace <corect>`
