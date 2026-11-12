####################################################################################
### Istio service mesh
###
### Installs Istio via its official Helm charts, served anonymously from
### https://istio-release.storage.googleapis.com/charts. Three charts, applied
### in the required order:
###
###   1. base    -> installs the Istio CRDs and cluster-wide roles
###   2. istiod  -> the control plane (xDS, sidecar injection webhook, CA for mTLS)
###   3. gateway -> an ingress gateway Deployment + LoadBalancer Service (an AWS
###                 ELB/NLB) that fronts traffic entering the mesh
###
### After `terraform apply`, label any namespace with `istio-injection=enabled`
### (the demo manifests in k8s-manifests/istio already do this) so that istiod
### injects an Envoy sidecar into every pod. The sidecars are the data plane:
### they carry all service-to-service traffic, enforce mTLS, and apply the
### VirtualService / DestinationRule / PeerAuthentication rules you define.
###
### NOTE: configuration is passed via `values = [yamlencode(...)]`. The Helm
### provider v3 changed the `set {}` block into a list attribute, so the
### yamlencode style used here is the version-safe way to set chart values.
####################################################################################

# 1) CRDs + cluster roles. Everything else depends on these existing first.
resource "helm_release" "istio_base" {
  name             = "istio-base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  version          = var.istio_version
  namespace        = var.istio_namespace
  create_namespace = true

  values = [
    yamlencode({
      defaultRevision = "default"
    })
  ]

  depends_on = [
    module.eks,
    null_resource.update_kubeconfig
  ]
}

# 2) The Istio control plane (istiod).
resource "helm_release" "istiod" {
  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = var.istio_version
  namespace  = var.istio_namespace
  wait       = true

  values = [
    yamlencode({
      # Automatically upgrade plaintext calls to mutual TLS when both sides have
      # a sidecar. Namespaces can still pin STRICT mTLS with PeerAuthentication
      # (see the demo manifests).
      meshConfig = {
        enableAutoMtls = true
      }
    })
  ]

  depends_on = [helm_release.istio_base]
}

# 3) The ingress gateway. The gateway chart creates a Service of type
#    LoadBalancer, which AWS fulfils with an external ELB. Traffic hits this LB,
#    enters the mesh through the gateway proxy, and is routed by the Gateway +
#    VirtualService resources in k8s-manifests/istio.
#
#    NOTE: `wait = true` makes Helm block until the LoadBalancer Service has an
#    external address. AWS can take several minutes to provision the ELB, which
#    exceeds Helm's default 5-minute (300s) timeout, so `timeout` is raised to
#    900s. `cleanup_on_fail` lets a timed-out/failed release be rolled back and
#    recreated cleanly on the next apply instead of getting stuck.
resource "helm_release" "istio_ingressgateway" {
  name             = "istio-ingressgateway"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "gateway"
  version          = var.istio_version
  namespace        = var.istio_ingress_namespace
  create_namespace = true
  wait             = true
  timeout          = 900
  cleanup_on_fail  = true

  values = [
    yamlencode({
      service = {
        type = "LoadBalancer"
      }
    })
  ]

  depends_on = [helm_release.istiod]
}
