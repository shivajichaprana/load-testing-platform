# The provider is configured by the caller's environment rather than by a
# profile or a key pair written here: a load fleet is deployed from a pipeline
# far more often than from a laptop, and a hard-coded profile name is the
# first thing that breaks when it is.
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.tags
  }
}
