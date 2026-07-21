terraform {
  required_version = ">= 1.6"

  # Runs execute in the HCP Terraform organization and existing workspace
  # supplied through TF_CLOUD_ORGANIZATION and TF_WORKSPACE.
  cloud {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = var.region
  # No credentials block: HCP Terraform supplies short-lived AWS creds at run
  # time via OIDC dynamic provider credentials (TFC_AWS_PROVIDER_AUTH /
  # TFC_AWS_RUN_ROLE_ARN set on the workspace). No static keys anywhere.

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Project   = "secure-sdlc-demo"
    }
  }
}
