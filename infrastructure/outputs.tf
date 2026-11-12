output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "cluster_security_group_id" {
  description = "Security group ids attached to the cluster control plane"
  value       = module.eks.cluster_security_group_id
}

output "cluster_iam_role_name" {
  description = "IAM role name associated with EKS cluster"
  value       = module.eks.cluster_iam_role_name
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  value       = module.eks.cluster_certificate_authority_data
}

output "cluster_name" {
  description = "The name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "vpc_id" {
  description = "ID of the VPC where the cluster is deployed"
  value       = module.vpc.vpc_id
}

output "private_subnets" {
  description = "List of IDs of private subnets"
  value       = module.vpc.private_subnets
}

output "public_subnets" {
  description = "List of IDs of public subnets"
  value       = module.vpc.public_subnets
}

################################################################################
# Istio Outputs
################################################################################
output "istio_version" {
  description = "Version of the Istio charts installed on the cluster"
  value       = var.istio_version
}

output "istio_namespace" {
  description = "Namespace hosting the Istio control plane (istiod)"
  value       = helm_release.istiod.namespace
}

output "istio_ingress_namespace" {
  description = "Namespace hosting the Istio ingress gateway"
  value       = helm_release.istio_ingressgateway.namespace
}

output "istio_ingressgateway_hint" {
  description = "Command to fetch the external address of the Istio ingress gateway load balancer"
  value       = "kubectl -n ${var.istio_ingress_namespace} get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
}
