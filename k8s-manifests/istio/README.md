# Istio service mesh demo manifests

These manifests demonstrate the core things a service mesh does, using two
versions of a small Node.js app. Istio itself is installed by the Terraform in
[`../../infrastructure`](../../infrastructure) (the `base`, `istiod`, and
`gateway` Helm releases); these files only deploy the demo workload and the mesh
configuration around it.

## What each file shows

| File | Mesh concept | What to look at |
|------|--------------|-----------------|
| `01-namespace.yaml` | **Sidecar injection** | `istio-injection=enabled` makes istiod inject an Envoy proxy into every pod. Pods show `2/2` containers. |
| `02-deployments.yaml` | **Service vs. versions** | Two Deployments (`v1`, `v2`) behind one Service. One named port fronts both images (8080 / 8081). |
| `03-destinationrule.yaml` | **Subsets, mTLS, circuit breaking** | Defines the `v1`/`v2` subsets, `ISTIO_MUTUAL` TLS, connection pool limits and outlier detection. |
| `04-gateway-virtualservice.yaml` | **Ingress + traffic management** | Gateway is the front door; VirtualService does an 80/20 canary split, header routing, timeouts and retries. |
| `05-peer-authentication.yaml` | **Zero-trust mTLS** | `STRICT` mode makes sidecars refuse any non-mTLS traffic. |
| `06-authorization-policy.yaml` | **L7 authorization** | Allow rules based on verified workload identity and HTTP method. |

## Apply

```bash
kubectl apply -f 01-namespace.yaml
kubectl apply -f 02-deployments.yaml
kubectl apply -f 03-destinationrule.yaml
kubectl apply -f 04-gateway-virtualservice.yaml
kubectl apply -f 05-peer-authentication.yaml
kubectl apply -f 06-authorization-policy.yaml
```

## Exercise the mesh

```bash
# External address of the ingress gateway load balancer (from Terraform output
# istio_ingressgateway_hint, or directly):
GW=$(kubectl -n istio-ingress get svc istio-ingressgateway \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Weighted canary: roughly 80% v1, 20% v2 across many calls.
for i in $(seq 1 20); do curl -s "http://$GW/"; echo; done

# Header routing: always hit v2.
curl -s -H "x-version: v2" "http://$GW/"

# Shift the canary to 50/50 by editing the weights in
# 04-gateway-virtualservice.yaml and re-applying — no app redeploy.
```

## Observability (optional)

Install the Istio sample addons to see the mesh topology and traffic:

```bash
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.27/samples/addons/kiali.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.27/samples/addons/prometheus.yaml
istioctl dashboard kiali
```

## Clean up

```bash
kubectl delete -f 06-authorization-policy.yaml -f 05-peer-authentication.yaml \
  -f 04-gateway-virtualservice.yaml -f 03-destinationrule.yaml \
  -f 02-deployments.yaml -f 01-namespace.yaml
```
