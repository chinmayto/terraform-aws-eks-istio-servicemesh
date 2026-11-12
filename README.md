---
title: "Hands-on with Istio Service Mesh on Amazon EKS (Terraform + Helm)"
published: false
description: "Spin up an EKS cluster with Terraform, install Istio via Helm, and learn the mesh one YAML file at a time: sidecar injection, mTLS, canary traffic splitting, ingress routing, and L7 authorization."
tags: kubernetes, istio, aws, terraform
---

# Hands-on with Istio Service Mesh on Amazon EKS

Microservices solve a lot of problems and create a few new ones. Once you have more than a handful of services talking to each other, questions pile up fast. How do you encrypt service-to-service traffic? How do you shift 10% of traffic to a new version without a redeploy? How do you retry a flaky call, or stop a failing pod from taking everything down? How do you know which service is actually talking to which?

A **service mesh** answers those questions at the infrastructure layer instead of inside every application. In this post we build one end to end: an Amazon EKS cluster provisioned with Terraform, [Istio](https://istio.io/) installed with Helm, and a small demo app that we use to exercise the mesh **one YAML file at a time**.

By the end you will understand, with runnable examples:

- **Sidecar injection** — how Istio gets into the request path without touching app code
- **Mutual TLS (mTLS)** — automatic in-cluster encryption and workload identity
- **Traffic management** — weighted canary splits, header-based routing, retries, timeouts
- **Resilience** — connection pooling and circuit breaking
- **Authorization** — L7 access control based on verified identity

## What is a service mesh (in one paragraph)?

A service mesh puts a small proxy (Istio uses [Envoy](https://www.envoyproxy.io/)) next to every workload. That proxy, the **sidecar**, intercepts all traffic entering and leaving the pod. The sidecars together form the **data plane**. A **control plane** (Istio's `istiod`) configures all those proxies and hands out TLS certificates. Because the proxy sits in the network path, the mesh can encrypt, route, retry, and measure traffic without the application knowing it exists.

## Architecture

We deploy a two-version app behind the Istio ingress gateway and let mesh configuration control everything in between.

```
                         ┌───────────────────────────────────────────────┐
   Internet ──► AWS ELB ─┤ istio-ingress ns: istio-ingressgateway (Envoy) │
                         └───────────────────┬───────────────────────────┘
                                             │ Gateway + VirtualService
                                             ▼
                         ┌───────────────────────────────────────────────┐
                         │ istio-demo ns (istio-injection=enabled)        │
                         │                                                │
                         │   Service: nodejs-app  ──► 80% ─► Deploy v1    │
                         │                            └─ 20% ─► Deploy v2  │
                         │   (each pod = app + injected Envoy sidecar)    │
                         └───────────────────────────────────────────────┘
                                             ▲
                         ┌───────────────────┴───────────────────────────┐
                         │ istio-system ns: istiod (control plane, mTLS CA)│
                         └───────────────────────────────────────────────┘
```

The building blocks:

- **VPC** — two Availability Zones, public and private subnets, a single NAT gateway (`terraform-aws-modules/vpc/aws`).
- **EKS** — a managed cluster with one managed node group that hosts everything: the Istio control plane, the ingress gateway, and the demo pods with their sidecars (`terraform-aws-modules/eks/aws`).
- **Istio** — installed from the official Helm charts (`base`, `istiod`, `gateway`).
- **Demo app** — two Deployments (`v1`, `v2`) of a small Node.js service behind a single Kubernetes Service.

## Prerequisites

- Terraform `>= 1.9`
- AWS CLI v2, authenticated with permission to create VPC, EKS, IAM, and ELB resources
- `kubectl`, and optionally [`istioctl`](https://istio.io/latest/docs/setup/getting-started/#download)
- An S3 bucket for Terraform remote state

## Step 1 — Provision EKS and install Istio with Terraform

The cluster and mesh are created together. The interesting part is `istio.tf`, which installs Istio as three Helm releases in the required order: `base` (CRDs), then `istiod` (control plane), then `gateway` (ingress). Values are passed with `yamlencode` so the config stays valid under the Helm provider v3.

```hcl
# infrastructure/istio.tf (excerpt)

# 1) CRDs + cluster roles — everything else depends on these.
resource "helm_release" "istio_base" {
  name             = "istio-base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  version          = var.istio_version
  namespace        = var.istio_namespace
  create_namespace = true

  depends_on = [module.eks, null_resource.update_kubeconfig]
}

# 2) The Istio control plane (istiod), with mesh-wide auto-mTLS.
resource "helm_release" "istiod" {
  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = var.istio_version
  namespace  = var.istio_namespace
  wait       = true

  values = [yamlencode({ meshConfig = { enableAutoMtls = true } })]

  depends_on = [helm_release.istio_base]
}

# 3) Ingress gateway — creates a Service of type LoadBalancer (an AWS ELB).
resource "helm_release" "istio_ingressgateway" {
  name             = "istio-ingressgateway"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "gateway"
  version          = var.istio_version
  namespace        = var.istio_ingress_namespace
  create_namespace = true
  wait             = true

  values = [yamlencode({ service = { type = "LoadBalancer" } })]

  depends_on = [helm_release.istiod]
}
```

Apply it:

```bash
cd infrastructure
terraform init
terraform apply
```

Terraform creates the cluster, updates your kubeconfig, and installs Istio. Confirm the control plane and gateway are running:

```bash
kubectl get pods -n istio-system
kubectl get pods -n istio-ingress
kubectl -n istio-ingress get svc istio-ingressgateway   # note the EXTERNAL-IP
```

## Step 2 — Use Istio one YAML file at a time

All demo manifests live in `k8s-manifests/istio/`. They are numbered so you can apply them in order and watch behavior change at each step. Each file isolates **one** mesh capability.

### 2.1 Sidecar injection — the foundation

The single label `istio-injection=enabled` is the whole mechanism. When `istiod` sees a pod created in a labelled namespace, its webhook injects an Envoy sidecar. That sidecar is what makes everything else possible.

```yaml
# 01-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: istio-demo
  labels:
    istio-injection: enabled
```

After applying, pods in this namespace report `2/2` containers: your app plus `istio-proxy`.

```bash
kubectl apply -f k8s-manifests/istio/01-namespace.yaml
```

### 2.2 Two versions behind one Service

Here is the thing worth managing: two Deployments of the same app, labelled `version: v1` and `version: v2`, behind one Service that selects on `app` only. On its own, Kubernetes would spread traffic randomly across all pods. Istio will take over that decision in the next files.

A neat detail: the two demo images listen on different ports (8080 and 8081), so each Deployment **names** its container port `http`, and the Service targets the port **by name**. Kubernetes resolves a named `targetPort` per pod, so one Service cleanly fronts both versions.

```yaml
# 02-deployments.yaml (excerpt)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nodejs-app-v1
  namespace: istio-demo
  labels: { app: nodejs-app, version: v1 }
spec:
  replicas: 2
  selector:
    matchLabels: { app: nodejs-app, version: v1 }
  template:
    metadata:
      labels: { app: nodejs-app, version: v1 }
    spec:
      containers:
        - name: nodejs-app
          image: public.ecr.aws/n4o6g6h8/simple-nodejs-app-1:latest
          ports:
            - name: http          # named port
              containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: nodejs-app
  namespace: istio-demo
spec:
  selector:
    app: nodejs-app              # matches BOTH v1 and v2
  ports:
    - name: http                 # prefix lets Istio detect the L7 protocol
      port: 80
      targetPort: http           # resolves to 8080 (v1) or 8081 (v2) per pod
```

```bash
kubectl apply -f k8s-manifests/istio/02-deployments.yaml
```

### 2.3 DestinationRule — subsets, mTLS, and circuit breaking

A `DestinationRule` describes what happens *after* routing picks a service. It names the **subsets** (`v1`, `v2`) that routing rules refer to, enforces mutual TLS to the upstream, and adds resilience through connection limits and outlier detection (circuit breaking).

```yaml
# 03-destinationrule.yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: nodejs-app
  namespace: istio-demo
spec:
  host: nodejs-app.istio-demo.svc.cluster.local
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL                 # encrypt upstream calls with Istio certs
    connectionPool:
      tcp: { maxConnections: 100 }
      http:
        http1MaxPendingRequests: 100
        maxRequestsPerConnection: 10
    outlierDetection:                    # circuit breaking
      consecutive5xxErrors: 5
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
  subsets:
    - name: v1
      labels: { version: v1 }
    - name: v2
      labels: { version: v2 }
```

```bash
kubectl apply -f k8s-manifests/istio/03-destinationrule.yaml
```

### 2.4 Gateway + VirtualService — ingress and traffic management

This is the headline. The `Gateway` binds the ingress gateway LoadBalancer to HTTP:80 (the mesh front door). The `VirtualService` holds the routing rules:

- **Weighted canary split** — 80% to `v1`, 20% to `v2`. Change the weights, re-apply, done. No app redeploy.
- **Header-based routing** — a request with `x-version: v2` always lands on v2, regardless of weights.
- **Retries and timeout** — resilience added by the mesh, not the app.

```yaml
# 04-gateway-virtualservice.yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: nodejs-app-gateway
  namespace: istio-demo
spec:
  selector:
    istio: ingressgateway        # matches the istio/gateway Helm release pods
  servers:
    - port: { number: 80, name: http, protocol: HTTP }
      hosts: ["*"]
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: nodejs-app
  namespace: istio-demo
spec:
  hosts: ["*"]
  gateways: [nodejs-app-gateway]
  http:
    # Rule 1: explicit opt-in to v2 via request header.
    - match:
        - headers:
            x-version: { exact: v2 }
      route:
        - destination:
            host: nodejs-app.istio-demo.svc.cluster.local
            subset: v2
    # Rule 2: default weighted canary for everyone else.
    - route:
        - destination: { host: nodejs-app.istio-demo.svc.cluster.local, subset: v1 }
          weight: 80
        - destination: { host: nodejs-app.istio-demo.svc.cluster.local, subset: v2 }
          weight: 20
      timeout: 5s
      retries:
        attempts: 3
        perTryTimeout: 2s
        retryOn: 5xx,reset,connect-failure
```

```bash
kubectl apply -f k8s-manifests/istio/04-gateway-virtualservice.yaml
```

Now test it against the gateway's external address:

```bash
GW=$(kubectl -n istio-ingress get svc istio-ingressgateway \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# ~80/20 split across many requests
for i in $(seq 1 20); do curl -s "http://$GW/"; echo; done

# Force v2 via header
curl -s -H "x-version: v2" "http://$GW/"
```

Want a 50/50 canary? Edit the two `weight` values and re-apply. That is traffic engineering without rebuilding or redeploying the app.

### 2.5 PeerAuthentication — zero-trust mTLS

`istiod` is a certificate authority: it issues a short-lived identity cert to every sidecar. Setting `STRICT` mode makes each sidecar in the namespace **reject any non-mTLS traffic**. You get in-cluster encryption and cryptographic workload identity with one tiny resource.

```yaml
# 05-peer-authentication.yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-demo
spec:
  mtls:
    mode: STRICT
```

```bash
kubectl apply -f k8s-manifests/istio/05-peer-authentication.yaml

# Verify (requires istioctl):
istioctl authn tls-check \
  $(kubectl -n istio-demo get pod -l version=v1 -o jsonpath='{.items[0].metadata.name}').istio-demo \
  nodejs-app.istio-demo.svc.cluster.local
```

> Migrating an existing app? Start with `PERMISSIVE` so non-meshed clients still work, then tighten to `STRICT` once everything has a sidecar.

### 2.6 AuthorizationPolicy — L7 access control

mTLS proves *who* is calling; `AuthorizationPolicy` decides *what* they may do. Because the sidecar terminates mTLS, the policy can match on verified source identity (principal) and HTTP attributes like method and path. Once any `ALLOW` policy applies to a workload, only matching requests get through.

```yaml
# 06-authorization-policy.yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: nodejs-app-allow
  namespace: istio-demo
spec:
  selector:
    matchLabels: { app: nodejs-app }
  action: ALLOW
  rules:
    # 1) Allow traffic coming in through the Istio ingress gateway.
    - from:
        - source:
            principals: ["cluster.local/ns/istio-ingress/sa/istio-ingressgateway"]
    # 2) Allow GET from any workload inside the istio-demo namespace.
    - from:
        - source: { namespaces: ["istio-demo"] }
      to:
        - operation: { methods: ["GET"] }
```

```bash
kubectl apply -f k8s-manifests/istio/06-authorization-policy.yaml
```

### Putting it together: the request path

```
curl http://<gateway-lb>/           (optional header x-version: v2)
        │                                    │
        ▼                                    ▼
   Gateway (:80)                      VirtualService rule 1 → subset v2 (pinned)
        │
        ▼
   VirtualService default rule → 80% v1 / 20% v2
        → DestinationRule resolves subset → pods, ISTIO_MUTUAL
        → PeerAuthentication enforces STRICT mTLS
        → AuthorizationPolicy checks identity + method
        → app container
```

## Observability (optional but worth it)

Install the Istio sample addons to *see* the mesh instead of inferring it from `curl`:

```bash
REL=release-1.27
kubectl apply -f https://raw.githubusercontent.com/istio/istio/$REL/samples/addons/prometheus.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/$REL/samples/addons/kiali.yaml
istioctl dashboard kiali
```

Kiali draws the live service graph and shows the 80/20 traffic distribution, mTLS lock icons, and request rates per version.

## Cleanup

Delete the Kubernetes resources **before** destroying infrastructure, so the gateway's AWS load balancer is removed before the VPC. An orphaned ELB will make `terraform destroy` hang on VPC deletion.

```bash
# 1) Remove the demo (reverse order is fine)
kubectl delete -f k8s-manifests/istio/

# 2) (If installed) remove the observability addons
REL=release-1.27
kubectl delete -f https://raw.githubusercontent.com/istio/istio/$REL/samples/addons/kiali.yaml
kubectl delete -f https://raw.githubusercontent.com/istio/istio/$REL/samples/addons/prometheus.yaml

# 3) Tear down EKS, Istio, and the VPC
cd infrastructure
terraform destroy
```

## Conclusion

The point of a service mesh is that none of what we did, encryption, canary routing, retries, circuit breaking, identity-based authorization, required a single line of application code or a new image. It all came from a handful of declarative YAML resources that the Envoy sidecars enforce in the request path.

Working through the manifests in order makes the model click:

- The namespace label gets a proxy next to every pod.
- `Gateway` and `VirtualService` decide *where* traffic goes and let you shift it with weights and headers.
- `DestinationRule` decides *how* it gets there, with mTLS and circuit breaking.
- `PeerAuthentication` and `AuthorizationPolicy` decide *who* is allowed to talk to *whom*.

From here, natural next steps are canary automation with [Argo Rollouts](https://argoproj.github.io/rollouts/) or [Flagger](https://flagger.app/), fault injection for chaos testing, and Istio's [ambient mode](https://istio.io/latest/docs/ambient/) to run the mesh without per-pod sidecars.

## References

- Project repository: [chinmayto/terraform-aws-eks-istio-servicemesh](https://github.com/chinmayto/terraform-aws-eks-istio-servicemesh)
- [Istio documentation](https://istio.io/latest/docs/)
- [Istio: Install with Helm](https://istio.io/latest/docs/setup/install/helm/)
- [Istio traffic management concepts](https://istio.io/latest/docs/concepts/traffic-management/)
- [Istio security (mTLS & authorization)](https://istio.io/latest/docs/concepts/security/)
- [Amazon EKS documentation](https://docs.aws.amazon.com/eks/latest/userguide/what-is-eks.html)
- [terraform-aws-modules/eks/aws](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest)
- [terraform-aws-modules/vpc/aws](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest)
- [Terraform Helm provider](https://registry.terraform.io/providers/hashicorp/helm/latest/docs)
