# nginx-ingress

Controller Ingress — expune servicii HTTP/HTTPS prin `Ingress` resources.

| | |
|---|---|
| Application | `argo-apps/infra-nginx-ingress.yaml` |
| Chart | `kubernetes/ingress-nginx` v4.11.3 |
| Namespace | `ingress-nginx` |
| Service type | `LoadBalancer` (K3s mapează automat 80/443) |
| IngressClass | `nginx` (default) |

## Verify

```bash
kubectl -n ingress-nginx get pods
kubectl -n ingress-nginx get svc
```

Service-ul `nginx-ingress-controller` trebuie să aibă `EXTERNAL-IP` (LoadBalancer) — pe K3s e IP-ul nodului.

## Edit hint

- `controller.service.type`: `LoadBalancer` cu port-forward 80/443 vs `ClusterIP` cu tunnel agent
- `controller.config.use-forwarded-headers`: `true` dacă ești în spatele unui proxy/CDN
- `controller.resources.limits` la 500m/512Mi — crește dacă vezi pod OOMKilled

## Anatomie Ingress resource

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts: [app.<domeniu>]
      secretName: app-tls
  rules:
    - host: app.<domeniu>
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: <svc-name>
                port: { number: 80 }
```
