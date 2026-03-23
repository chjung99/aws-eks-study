terraform {
  cloud {
    organization = "aws-eks-study"

    workspaces {
      name = "aws-eks-study"
    }
  }
}
