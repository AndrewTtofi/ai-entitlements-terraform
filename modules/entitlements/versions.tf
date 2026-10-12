terraform {
  required_version = ">= 1.9"
  required_providers {
    okta = {
      source  = "okta/okta"
      version = "~> 7.0"
    }
  }
}
