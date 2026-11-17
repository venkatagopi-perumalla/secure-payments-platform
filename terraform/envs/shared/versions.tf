terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {
    bucket       = "payments-tfstate-472639329900"
    key          = "shared/terraform.tfstate"
    region       = "eu-north-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = "secure-payments-platform"
      Environment = "shared"
      ManagedBy   = "terraform"
      CostCenter  = "payments-lab"
    }
  }
}

variable "region" {
  type    = string
  default = "eu-north-1"
}
