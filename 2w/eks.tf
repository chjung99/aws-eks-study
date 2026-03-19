########################
# Provider Definitions #
########################

# AWS 공급자: 지정된 리전에서 AWS 리소스를 설정
provider "aws" {
  region = var.TargetRegion
}


########################
# Security Group Setup #
########################

# 보안 그룹: EKS 워커 노드용 보안 그룹 생성
resource "aws_security_group" "node_group_sg" {
  name        = "${var.ClusterBaseName}-node-group-sg"
  description = "Security group for EKS Node Group"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "${var.ClusterBaseName}-node-group-sg"
  }
}

# 보안 그룹 규칙: EKS 워커 노드로 접속 허용
resource "aws_security_group_rule" "allow_ssh" {
  type        = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks = [
    var.ssh_access_cidr,
    var.VpcBlock
  ]
  security_group_id = aws_security_group.node_group_sg.id
}


########################
# EKS
########################

# https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest
module "eks" {
  
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.ClusterBaseName
  kubernetes_version = var.KubernetesVersion

  vpc_id = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  enable_irsa = true

  endpoint_public_access = true
  endpoint_private_access = true
  # endpoint_public_access_cidrs = [
  #   var.ssh_access_cidr
  # ]

  # controlplane log
  enabled_log_types = []

  # Optional: Adds the current caller identity as an administrator via cluster access entry
  enable_cluster_creator_admin_permissions = true

  # EKS Managed Node Group(s)
  eks_managed_node_groups = {
    # 1st 노드 그룹
    primary = {
      name             = "${var.ClusterBaseName}-1nd-node-group"
      use_name_prefix  = false
      instance_types   = ["${var.WorkerNodeInstanceType}"]
      desired_size     = var.WorkerNodeCount
      max_size         = var.WorkerNodeCount + 2
      min_size         = var.WorkerNodeCount - 1
      disk_size        = var.WorkerNodeVolumesize
      subnets          = module.vpc.public_subnets
      key_name         = "${var.KeyName}"
      vpc_security_group_ids = [aws_security_group.node_group_sg.id]
      
      # node label
      labels = {
        tier = "primary"
      }

      # AL2023 전용 userdata 주입
      cloudinit_pre_nodeadm = [
        {
          content_type = "text/x-shellscript"
          content      = <<-EOT
            #!/bin/bash
            echo "Starting custom initialization..."
            dnf update -y
            dnf install -y tree bind-utils tcpdump nvme-cli links sysstat ipset htop
            echo "Custom initialization completed."
          EOT
        }
      ]
    }

    # 2nd 노드 그룹 (추가)
    # secondary = {
    #   name            = "${var.ClusterBaseName}-2nd-node-group"
    #   use_name_prefix = false
    
    #   instance_types  = ["c5.large"] 
    #   desired_size    = 1
    #   max_size        = 1
    #   min_size        = 1
      
    #   subnets          = module.vpc.public_subnets  # module.vpc.private_subnets
    #   key_name         = "${var.KeyName}"
    #   vpc_security_group_ids = [aws_security_group.node_group_sg.id]
      
    #   # node label
    #   labels = {
    #     tier = "secondary"
    #   }

    #   # AL2023 전용 userdata 주입
    #   cloudinit_pre_nodeadm = [
    #     {
    #       content_type = "text/x-shellscript"
    #       content      = <<-EOT
    #         #!/bin/bash
    #         echo "Starting custom initialization..."
    #         dnf update -y
    #         dnf install -y tree bind-utils tcpdump nvme-cli links sysstat ipset htop
    #         echo "Custom initialization completed."
    #       EOT
    #     }
    #   ]
    # }

  }

  # add-on
  addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
      before_compute = true
      configuration_values = jsonencode({
        env = {
          WARM_ENI_TARGET = "1" # 현재 ENI 외에 여유 ENI 1개를 항상 확보
          #WARM_IP_TARGET  = "5" # 현재 사용 중인 IP 외에 여유 IP 5개를 항상 유지, 설정 시 WARM_ENI_TARGET 무시됨
          #MINIMUM_IP_TARGET   = "10" # 노드 시작 시 최소 확보해야 할 IP 총량 10개
          #ENABLE_PREFIX_DELEGATION = "true" 
          #WARM_PREFIX_TARGET = "1" # PREFIX_DELEGATION 사용 시, 1개의 여유 대역(/28) 유지
        }
      })
    }
  }

  tags = {
    Environment = "cloudneta-lab"
    Terraform   = "true"
  }

}
