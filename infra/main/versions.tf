terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72"
    }
  }

  # The bucket name includes the account ID, so it is supplied at init time:
  #   terraform init -backend-config="bucket=$(terraform -chdir=../bootstrap output -raw state_bucket)"
  backend "s3" {
    key          = "leadpipe/main.tfstate"
    encrypt      = true
    use_lockfile = true # S3-native state locking. DynamoDB is no longer needed.
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "main"
    }
  }
}
