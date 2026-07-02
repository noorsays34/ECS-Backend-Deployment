terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket = "krish-myapp-terraform-state"
    key    = "ecs/terraform.tfstate"
    region = "ap-south-1"
  }
}

provider "aws" {
  region = var.region
}