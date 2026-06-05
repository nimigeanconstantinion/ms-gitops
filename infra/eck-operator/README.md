# eck-operator

Elastic Cloud on Kubernetes — operator pentru CR-uri Elasticsearch / Kibana / Logstash / Beats / ApmServer.

| | |
|---|---|
| Application | `argo-apps/infra-eck.yaml` |
| Chart | `elastic/eck-operator` v3.4.0 |
| Namespace | `elastic-system` |

## ⚠️ Bug-uri curente (vezi CODE_REVIEW.md)

- Lipsă `ServerSideApply=true` în syncOptions → risc "request entity too large" la apply CRD-uri mari
- Lipsă `sync-wave: "0"` explicit (e implicit 0, dar inconsistent cu pattern-ul tău)
- Comentariu greșit la linia 12 ("Sealed Secrets" în loc de "ECK")

## CRD-uri principale

- `Elasticsearch` (deja folosit — vezi `infra/elasticsearch/`)
- `Kibana` ⬅ NEXT — vizualizare logs/metrics
- `Logstash` — pipeline ingest
- `Beats` — collectors (Filebeat, Metricbeat)
- `ApmServer` — APM tracking

## Verify

```bash
kubectl -n elastic-system get pods
kubectl get crd | grep elastic.co
```

Operator pod: `elastic-operator-0`.

## Edit hint

`values.yaml` — minim acum. Custom common:
- `installCRDs: true` (default)
- `replicaCount: 1` (HA pentru prod = 3)
- `manageNamespace: false` dacă vrei să gestionezi ns separat

## Next CR de adăugat

**Kibana** (vezi catalog `argo-apps/README.md` → layer CR-uri):
```yaml
# infra/kibana/kibana.yaml
apiVersion: kibana.k8s.elastic.co/v1
kind: Kibana
metadata:
  name: kibana
  namespace: elastic-system
spec:
  version: 8.15.3   # = versiunea Elasticsearch
  count: 1
  elasticsearchRef:
    name: elasticsearch
```

Plus Application separat `argo-apps/infra-kibana.yaml` wave 3.
