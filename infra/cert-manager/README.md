# cert-manager

Operator pentru certificate TLS automate (Let's Encrypt + alte CA-uri).

| | |
|---|---|
| Application | `argo-apps/infra-cert-manager.yaml` |
| Chart | `jetstack/cert-manager` v1.16.2 |
| Namespace | `cert-manager` |
| Install CRDs | `installCRDs: true` |

## CRD-uri principale

- `ClusterIssuer` — cluster-scoped issuer (folosit aici, vezi `cert-manager-issuers/`)
- `Issuer` — namespace-scoped
- `Certificate` — cere cert pentru un host
- `CertificateRequest` — generată automat de Certificate

## Verify

```bash
kubectl -n cert-manager get pods
kubectl get clusterissuer
kubectl get certificate -A
```

Toate 3 pod-uri trebuie `Running`: `cert-manager`, `cert-manager-webhook`, `cert-manager-cainjector`.

## Edit hint

- `resources.limits.memory: 128Mi` — minim safe; chart-ul oficial recomandă 256Mi pentru prod
- Webhook timeout: dacă API server e lent (EC2 small), pune `webhook.timeoutSeconds: 30`

## Folosire în Ingress

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  tls:
    - hosts: [app.<domeniu>]
      secretName: app-tls   # cert-manager creează automat acest secret
```

## Debug cert care nu se emite

```bash
kubectl describe certificate -A | grep -A 5 "Events:"
kubectl describe certificaterequest -A
kubectl describe order -A      # ACME Order resource
kubectl describe challenge -A  # ACME Challenge (HTTP01/DNS01)
```
