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

# 보안 그룹 규칙: 특정 IP에서 EKS 워커 노드로 all traffic 접속 허용
resource "aws_security_group_rule" "allow_ssh" {
  type        = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks = [
    var.VpcBlock
  ]
  security_group_id = aws_security_group.node_group_sg.id
}

################
# IAM Policies #
################

# AWS Load Balancer Controller가 ELB를 관리할 수 있도록 허용하는 IAM 정책
resource "aws_iam_policy" "aws_lb_controller_policy" {
  name        = "${var.ClusterBaseName}AWSLoadBalancerControllerPolicy"
  description = "Policy for allowing AWS LoadBalancerController to modify AWS ELB"
  policy = file("aws_lb_controller_policy.json")
}

# ExternalDNS가 Route 53 DNS 레코드를 관리할 수 있도록 허용하는 IAM 정책
resource "aws_iam_policy" "external_dns_policy" {
  name        = "${var.ClusterBaseName}ExternalDNSPolicy"
  description = "Policy for allowing ExternalDNS to modify Route 53 records"
  policy = file("externaldns_controller_policy.json")
}

# CAS가 AWS AutoScaling 관리할 수 있도록 허용하는 IAM 정책
resource "aws_iam_policy" "aws_cas_autoscaler_policy" {
  name        = "${var.ClusterBaseName}CasAutoScalerPolicy"
  description = "Policy for allowing CAS to management AWS AutoScaling"
  policy = file("cas_autoscaling_policy.json")
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
  subnet_ids = module.vpc.private_subnets

  enable_irsa = true

  endpoint_public_access = true
  endpoint_private_access = true

  # controlplane log
  enabled_log_types = [
    # audit, authenticator, controllerManager
    "api",
    "scheduler"
  ]

  # Optional: Adds the current caller identity as an administrator via cluster access entry
  enable_cluster_creator_admin_permissions = true

  # EKS Managed Node Group(s)
  eks_managed_node_groups = {
    # 1st 노드 그룹
    primary = {
      name             = "${var.ClusterBaseName}-ng-1"
      use_name_prefix  = false
      ami_type         = "AL2023_x86_64_STANDARD"
      instance_types   = ["${var.WorkerNodeInstanceType}"]
      desired_size     = var.WorkerNodeCount
      max_size         = var.WorkerNodeCount + 2
      min_size         = var.WorkerNodeCount - 1
      disk_size        = var.WorkerNodeVolumesize
      subnets          = module.vpc.private_subnets
      vpc_security_group_ids = [aws_security_group.node_group_sg.id]

      iam_role_name    = "${var.ClusterBaseName}-ng-1"
      iam_role_use_name_prefix = false
      # 학습을 위해 EC2 Instance Profile 에 필요한 IAM Role 추가
      iam_role_additional_policies = {
        "${var.ClusterBaseName}AWSLoadBalancerControllerPolicy" = aws_iam_policy.aws_lb_controller_policy.arn
        "${var.ClusterBaseName}ExternalDNSPolicy" = aws_iam_policy.external_dns_policy.arn
        "${var.ClusterBaseName}CasAutoScalerPolicy" = aws_iam_policy.aws_cas_autoscaler_policy.arn
        AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      # 노드에 배포된 파드에서 C2 Instance Profile 사용을 위해 EC2 메타데이터 호출을 위한 hop limit 2 증가
      metadata_options = {
        http_endpoint               = "enabled"    # IMDS 활성화
        http_tokens                 = "required"   # IMDSv2 강제
        http_put_response_hop_limit = 2            # hop limit = 2
        #instance_metadata_tags      = "disabled"  # 인스턴스 태그 메타데이터 비활성화
      }
      
      # node label
      labels = {
        tier = "primary"
      }

      # AL2023 전용 userdata 주입
      cloudinit_pre_nodeadm = [
        {
          content_type = "application/node.eks.aws"
          content      = <<-EOT
            ---
            apiVersion: node.eks.aws/v1alpha1
            kind: NodeConfig
            spec:
              kubelet:
                config:
                  maxPods: 50
          EOT
        },
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
    #   name            = "${var.ClusterBaseName}-ng-2"
    #   use_name_prefix = false
    #   ami_type        = "AL2023_ARM_64_STANDARD" # https://docs.aws.amazon.com/ko_kr/tnb/latest/ug/node-eks-managed-node.html#node-eks-managed-node-capabilities
    #   instance_types  = ["t4g.medium"] 
    #   desired_size    = 1
    #   max_size        = 1
    #   min_size        = 1
    #   disk_size        = var.WorkerNodeVolumesize
    #   subnets          = module.vpc.private_subnets
    #   vpc_security_group_ids = [aws_security_group.node_group_sg.id]

    #   iam_role_name    = "${var.ClusterBaseName}-ng-2"
    #   iam_role_use_name_prefix = false
    #   # 학습을 위해 EC2 Instance Profile 에 필요한 IAM Role 추가
    #   iam_role_additional_policies = {
    #     "${var.ClusterBaseName}AWSLoadBalancerControllerPolicy" = aws_iam_policy.aws_lb_controller_policy.arn
    #     "${var.ClusterBaseName}ExternalDNSPolicy" = aws_iam_policy.external_dns_policy.arn
    #     AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    #   }
      
    #   # 노드에 배포된 파드에서 C2 Instance Profile 사용을 위해 EC2 메타데이터 호출을 위한 hop limit 2 증가
    #   metadata_options = {
    #     http_endpoint               = "enabled"
    #     http_tokens                 = "required"   # IMDSv2 강제
    #     http_put_response_hop_limit = 2            # hop limit = 2
    #   }

    #   # node label
    #   labels = {
    #     tier = "secondary"
    #   }

    #   # node taint
    #   taints = {
    #     frontend = {
    #       key    = "cpuarch"
    #       value  = "arm64"
    #       effect = "NO_EXECUTE"
    #     }
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


    # 3nd 노드 그룹 (추가)
    # third = {
    #   name            = "${var.ClusterBaseName}-ng-3"
    #   use_name_prefix = false
    #   ami_type        = "AL2023_x86_64_STANDARD"
    #   # 스팟 인스턴스 설정의 핵심
    #   capacity_type   = "SPOT"
    #   instance_types  = ["c5a.large", "c6a.large", "t3a.large", "t3a.medium"]
    #   desired_size    = 1
    #   max_size        = 1
    #   min_size        = 1
    #   disk_size        = var.WorkerNodeVolumesize
    #   subnets          = module.vpc.private_subnets
    #   vpc_security_group_ids = [aws_security_group.node_group_sg.id]

    #   iam_role_name    = "${var.ClusterBaseName}-ng-3"
    #   iam_role_use_name_prefix = false
    #   # 학습을 위해 EC2 Instance Profile 에 필요한 IAM Role 추가
    #   iam_role_additional_policies = {
    #     "${var.ClusterBaseName}AWSLoadBalancerControllerPolicy" = aws_iam_policy.aws_lb_controller_policy.arn
    #     "${var.ClusterBaseName}ExternalDNSPolicy" = aws_iam_policy.external_dns_policy.arn
    #     AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    #   }
      
    #   # 노드에 배포된 파드에서 C2 Instance Profile 사용을 위해 EC2 메타데이터 호출을 위한 hop limit 2 증가
    #   metadata_options = {
    #     http_endpoint               = "enabled"
    #     http_tokens                 = "required"   # IMDSv2 강제
    #     http_put_response_hop_limit = 2            # hop limit = 2
    #   }

    #   # node label
    #   labels = {
    #     tier = "third"
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
  # aws eks describe-addon-versions --kubernetes-version 1.35 | jq | grep addonName | sort
  # aws eks describe-addon-versions --kubernetes-version 1.34 | jq | grep addonName | sort
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
    }
    metrics-server = {
      most_recent = true
    }
    external-dns = {
      most_recent = true
      # configuration_values = jsonencode({
      #   extraArgs = {
      #     # --policy = sync 적용 방법 테스트 해보기
      #   }
      # })
    }
  }

  tags = {
    owner = "skax-11624"
    Terraform   = "true"
  }

}
