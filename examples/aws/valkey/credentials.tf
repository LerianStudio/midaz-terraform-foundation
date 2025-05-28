# Generate random auth token
resource "random_password" "valkey_auth" {
  length           = 32
  special          = true
  override_special = "!#$%&'()*+,-.:<=>?[]^_`{|}~"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

# Store auth token in AWS Secrets Manager
resource "aws_secretsmanager_secret" "valkey_auth" {
  name        = "${var.name}-auth/test"
  description = "Auth token for ${var.name} Valkey cluster"

  tags = merge(
    var.additional_tags,
    {
      Name        = "${var.name}-auth"
      Environment = var.environment
    }
  )
}

resource "aws_secretsmanager_secret_version" "valkey_auth" {
  secret_id     = aws_secretsmanager_secret.valkey_auth.id
  secret_string = random_password.valkey_auth.result
}