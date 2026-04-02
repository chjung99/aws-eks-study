terraform { 
  cloud { 
    
    organization = "aws-eks-study" 

    workspaces { 
      name = "week3" 
    } 
  } 
}