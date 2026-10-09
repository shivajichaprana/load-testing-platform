# Provider and language constraints for the root module.
#
# `check` blocks are used for the advisory assertions that describe what a run
# will MEASURE rather than whether it will deploy, so the floor is 1.5. The
# floor is set higher than that because `import` blocks and the improved
# `precondition` error rendering both matter when a fleet is adopted into an
# existing account.
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60.0, < 7.0.0"
    }
  }
}
