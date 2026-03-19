################################
# Security Group Configuration #
################################

# 보안 그룹: Bastion Host를 위한 보안 그룹을 생성
resource "aws_security_group" "eks_sec_group" {
  vpc_id = module.vpc.vpc_id

  name        = "${var.ClusterBaseName}-bastion-sg"

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.ssh_access_cidr] 
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.ClusterBaseName}-bastion-sg"
  }
}

######################
# EC2 Instance Setup #
######################

# 최신 Ubuntu 24.04 AMI ID를 AWS SSM Parameter Store에서 가져옴.
data "aws_ssm_parameter" "ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# EKS 클러스터 관리용 Bastion Host EC2 인스턴스를 생성.
resource "aws_instance" "eks_bastion" {
  ami                         = data.aws_ssm_parameter.ami.value
  instance_type               = "t3.medium"
  key_name                    = var.KeyName
  subnet_id                   = module.vpc.public_subnets[0]
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.eks_sec_group.id]

  tags = {
    Name = "${var.ClusterBaseName}-bastion"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    delete_on_termination = true
  }

  user_data = <<-EOF
    #!/bin/bash
    hostnamectl --static set-hostname "${var.ClusterBaseName}-bastion"

    # Config convenience
    echo 'alias vi=vim' >> /etc/profile
    echo "sudo su -" >> /home/ubuntu/.bashrc
    timedatectl set-timezone Asia/Seoul

    # Install Packages
    apt update
    apt install -y tree jq git htop unzip curl

    # Install kubectl & helm
    curl -O https://s3.us-west-2.amazonaws.com/amazon-eks/1.34.2/2025-11-13/bin/linux/amd64/kubectl
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    curl -s https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

    # Install eksctl
    curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /tmp
    mv /tmp/eksctl /usr/local/bin

    # Install aws cli v2
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip >/dev/null 2>&1
    ./aws/install
    complete -C '/usr/local/bin/aws_completer' aws
    echo 'export AWS_PAGER=""' >> /etc/profile

    # Install YAML Highlighter
    snap install yq

    # Install kube-ps1
    echo 'source <(kubectl completion bash)' >> /root/.bashrc
    echo 'alias k=kubectl' >> /root/.bashrc
    echo 'complete -F __start_kubectl k' >> /root/.bashrc
            
    git clone https://github.com/jonmosco/kube-ps1.git /root/kube-ps1
    cat << "EOT" >> /root/.bashrc
    source /root/kube-ps1/kube-ps1.sh
    KUBE_PS1_SYMBOL_ENABLE=false
    function get_cluster_short() {
      echo "$1" | cut -d . -f1
    }
    KUBE_PS1_CLUSTER_FUNCTION=get_cluster_short
    KUBE_PS1_SUFFIX=') '
    PS1='$(kube_ps1)'$PS1
    EOT

    # Install kubectx & kubens
    git clone https://github.com/ahmetb/kubectx /opt/kubectx >/dev/null 2>&1
    ln -s /opt/kubectx/kubens /usr/local/bin/kubens
    ln -s /opt/kubectx/kubectx /usr/local/bin/kubectx

  EOF
  
  user_data_replace_on_change = true
  
}

output "bastion_ec2-public_ip" {
  value       = aws_instance.eks_bastion.public_ip
  description = "The public IP of the bastion host EC2 instance."
}

# Allow Bastion to access EKS Cluster API
resource "aws_security_group_rule" "bastion_to_cluster" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.eks_sec_group.id
  security_group_id        = module.eks.cluster_security_group_id
}
