provider "aws" {
  region = local.region
}

provider "aws" {
  region = "us-east-1"
  alias  = "virginia"
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

data "aws_availability_zones" "available" {
  # Exclude local zones
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.virginia
}

locals {
  name   = "ex-karpenter"
  region = "eu-west-1"

  vpc_cidr = "10.76.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Example    = local.name
    GithubRepo = "terraform-aws-eks"
    GithubOrg  = "terraform-aws-modules"
  }
}
# Toggle for Fargate or Managed Node Group
variable "use_fargate" {
  description = "Set to true to use Fargate profiles, or false to use managed node groups."
  type        = bool
  default     = false
}
################################################################################
# EKS Module
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"
  cluster_name    = local.name
  cluster_version = "1.31"

  # Gives Terraform identity admin access to cluster which will
  # allow deploying resources (Karpenter) into the cluster
  enable_cluster_creator_admin_permissions = true
  cluster_endpoint_public_access           = true

  cluster_addons = {

    coredns                = var.use_fargate ? {
        most_recent = true,
        configuration_values = jsonencode({
        computeType = "fargate"
      })}: {}
    eks-pod-identity-agent = {}
    kube-proxy             = {}
    vpc-cni                = {}
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets
  # Fargate Profiles (Enabled based on the use_fargate variable)
  fargate_profiles = var.use_fargate ? {
    kube_system = {
      name = "kube-system"
      selectors = [
        {
          namespace = "kube-system"
          labels    = { k8s-app = "kube-dns" }
        },
        {
          namespace = "kube-system"
          labels    = { "app.kubernetes.io/name" = "karpenter" }
        }
      ]
    }
  } : {}

  eks_managed_node_groups = var.use_fargate ? {} : {
    karpenter = {
      ami_type       = "BOTTLEROCKET_x86_64"
      instance_types = ["t3.medium"]

      min_size     = 2
      max_size     = 3
      desired_size = 2

      labels = {
        # Used to ensure Karpenter runs on nodes that it does not manage
        "karpenter.sh/controller" = "true"
      }
    }
  }

  node_security_group_tags = merge(local.tags, {
    # NOTE - if creating multiple security groups with this module, only tag the
    # security group that Karpenter should utilize with the following tag
    # (i.e. - at most, only one security group should have this tag in your account)
    "karpenter.sh/discovery" = local.name
  })

  tags = local.tags
}

################################################################################
# Karpenter
################################################################################

module "fa-karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  count = var.use_fargate ? 1 : 0
  version = "~> 20.22"
  # Name needs to match role name passed to the EC2NodeClass
  node_iam_role_use_name_prefix = false
  enable_v1_permissions = true
  node_iam_role_name            = local.name
  # fargate only works with IRSA
  enable_pod_identity             = false
  create_pod_identity_association = false
  enable_irsa                     = true
  irsa_oidc_provider_arn          = module.eks.oidc_provider_arn
  irsa_namespace_service_accounts = ["kube-system:karpenter"]

  cluster_name = module.eks.cluster_name

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}
module "mag-karpenter" {
  source = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.31"
#  source = "../../modules/karpenter"
  count = var.use_fargate ? 0 : 1

  cluster_name          = module.eks.cluster_name
  enable_v1_permissions = true

  # Name needs to match role name passed to the EC2NodeClass
  node_iam_role_use_name_prefix   = false
  node_iam_role_name              = local.name
  create_pod_identity_association = true

  # Used to attach additional IAM policies to the Karpenter node IAM role
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}


################################################################################
# Karpenter Helm chart & manifests
# Not required; just to demonstrate functionality of the sub-module
################################################################################

resource "helm_release" "mag-karpenter" {
  namespace           = "kube-system"
  count = var.use_fargate ? 0 : 1
  name                = "karpenter"
  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart               = "karpenter"
  version             = "1.1.1"
  wait                = false

  values = [
    <<-EOT
    nodeSelector:
      karpenter.sh/controller: 'true'
    dnsPolicy: Default
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.mag-karpenter[0].queue_name}
    webhook:
      enabled: false
    EOT
  ]
}

resource "helm_release" "fa-karpenter" {
  namespace           = "kube-system"
  count = var.use_fargate ? 1 : 0
  name                = "karpenter"
  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart               = "karpenter"
  version             = "1.1.1"
  wait                = false

  values = [
    <<-EOT
    serviceAccount:
      name: ${module.fa-karpenter[0].service_account}
      annotations:
        eks.amazonaws.com/role-arn: ${module.fa-karpenter[0].iam_role_arn}
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.fa-karpenter[0].queue_name}
    tolerations:
      - key: CriticalAddonsOnly
        operator: Exists
      - key: eks.amazonaws.com/compute-type
        operator: Equal
        value: fargate
        effect: NoSchedule
    controller:
      resources:
        requests:
          cpu: 1000m
          memory: 1024Mi
        limits:
          cpu: 1000m
          memory: 1024Mi
    EOT
  ]

}
################################################################################
# Supporting Resources
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]
  intra_subnets   = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 52)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    # Tags subnets for Karpenter auto-discovery
    "karpenter.sh/discovery" = local.name
  }

  tags = local.tags
}
