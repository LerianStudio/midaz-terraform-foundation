################################################################################
# Lookups
#
# S3 bucket names are GLOBALLY unique across all AWS accounts, so the account id
# is appended to every name this module builds. That is the documented exception
# to the {product}-{environment}-{component} convention.
################################################################################

data "aws_caller_identity" "current" {}
