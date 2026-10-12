terraform {
  required_version = ">= 1.10"
  required_providers {
    aws   = { source = "hashicorp/aws", version = "~> 6.0" }
    local = { source = "hashicorp/local", version = "~> 2.5" }
  }
}

provider "aws" {
  region                      = "eu-west-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  skip_region_validation      = true
  s3_use_path_style           = true

  endpoints {
    ec2            = "http://127.0.0.1:5000"
    rds            = "http://127.0.0.1:5000"
    iam            = "http://172.30.0.10:4566"
    kms            = "http://172.30.0.10:4566"
    s3             = "http://172.30.0.10:4566"
    secretsmanager = "http://172.30.0.10:4566"
    sts            = "http://172.30.0.10:4566"
    logs           = "http://172.30.0.10:4566"
    cloudwatch     = "http://172.30.0.10:4566"
    ssm            = "http://172.30.0.10:4566"
  }
}