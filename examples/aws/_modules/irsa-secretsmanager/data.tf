data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# Partition rather than a literal "aws": the same policy has to render correctly in
# GovCloud and China, where the ARN partition is aws-us-gov / aws-cn.
data "aws_partition" "current" {}
