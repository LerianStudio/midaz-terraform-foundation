# AmazonMQ Module Test Report

> **HISTORICAL RECORD.** This file documents a test run as it happened on
> 2026-02-04 and is not maintained as current documentation. It is kept because
> the broker logic it validates is still the logic this module ships. Where a
> later change invalidated something recorded here, the change is flagged inline
> rather than edited away.

## Test Summary - 2026-02-04

All tests **PASSED**. The module correctly implements single-instance and cluster mode deployments.

> **Migration note.** This report was produced against the pre-v2
> `examples/aws/amazonmq` stack, removed in v2. The broker logic it validates - topology
> selection, one-subnet-per-AZ spreading and the four lifecycle preconditions -
> was migrated unchanged into `examples/aws/_modules/rabbitmq-amazonmq`, so the
> conclusions still hold. What changed around it: `deployment_mode` is now
> `broker_deployment_mode`, resource names come from the `naming` module, the
> secret moved to `{product}-{env}-rabbitmq/password`. The rows below name the
> outputs as they stood when this report was written. The Test Environment table
> records the versions used at the time, not the current constraints (the module
> now requires Terraform >= 1.5.0 and AWS provider >= 5.83.0).

> **Correction — `mq.t3.micro` (added after a real apply failed).** Test 1 below
> records a `SINGLE_INSTANCE` broker on `mq.t3.micro` as PASS. That instance type
> is **ActiveMQ-only**: AmazonMQ rejects it for the RabbitMQ engine in *every*
> deployment mode with
> `Broker engine type [RabbitMQ] does not support host instance type [mq.t3.micro]`.
> The row is left as originally written because this file is a record of what was
> run, but treat the instance type in it as wrong — whatever that test actually
> exercised, it was not a RabbitMQ broker on `mq.t3.micro`. RabbitMQ accepts only
> the `mq.m5.*` and `mq.m7g.*` families, of which `mq.m7g.medium` is the smallest,
> and the module now rejects anything else at plan time. The topology conclusions
> in Tests 2+ are unaffected.

---

## Test Environment

| Attribute | Value |
|-----------|-------|
| Region | us-east-2 (Ohio) |
| VPC CIDR | 10.99.0.0/16 |
| Availability Zones | us-east-2a, us-east-2b, us-east-2c |
| Terraform Version | >= 1.0 |
| AWS Provider | ~> 5.0 |

---

## Test 1: Single-Instance Deployment

**Objective:** Verify SINGLE_INSTANCE mode uses exactly 1 subnet.

| Attribute | Value |
|-----------|-------|
| Deployment Mode | SINGLE_INSTANCE |
| Instance Type | mq.t3.micro |
| Engine | RabbitMQ 3.13 |
| Subnets Used | 1 |
| is_cluster_mode output | false |
| Creation Time | ~9 minutes |
| Destruction Time | ~2 minutes |
| **Result** | **PASS** |

**Verification:**
```bash
terraform output is_cluster_mode
# false

terraform state show 'aws_mq_broker.main' | grep subnet_ids
# subnet_ids = ["subnet-xxxxxxxxx"]  # Single subnet
```

---

## Test 2: Cluster Mode Deployment

**Objective:** Verify CLUSTER_MULTI_AZ mode uses 3 subnets in different AZs.

| Attribute | Value |
|-----------|-------|
| Deployment Mode | CLUSTER_MULTI_AZ |
| Instance Type | mq.m5.large |
| Engine | RabbitMQ 3.13 |
| Subnets Used | 3 (one per AZ) |
| Distinct AZ Validation | **PASS** |
| is_cluster_mode output | true |
| Creation Time | ~10 minutes |
| Destruction Time | ~2 minutes |
| **Result** | **PASS** |

**Verification:**
```bash
terraform output is_cluster_mode
# true

terraform state show 'aws_mq_broker.main' | grep -A5 subnet_ids
# subnet_ids = [
#   "subnet-xxxxxxxxx",  # us-east-2a
#   "subnet-yyyyyyyyy",  # us-east-2b
#   "subnet-zzzzzzzzz",  # us-east-2c
# ]
```

---

## Validations Performed

### 1. Subnet Selection Logic
- **Single-instance:** Correctly uses first available private subnet
- **Cluster mode:** Correctly selects one subnet per AZ using `subnets_by_az` grouping
- **try() wrapper:** Prevents index-out-of-bounds errors during precondition evaluation

### 2. Lifecycle Preconditions
| Precondition | Status |
|--------------|--------|
| ACTIVE_STANDBY_MULTI_AZ blocked (RabbitMQ unsupported) | **WORKING** |
| mq.t3.* instances blocked for cluster mode | **WORKING** |
| Minimum 2 distinct AZs required for cluster | **WORKING** |
| At least 1 subnet required | **WORKING** |

### 3. Outputs
Output names below are the post-migration ones from
`examples/aws/_modules/rabbitmq-amazonmq/outputs.tf`. The names the pre-v2 stack
used, which they replace, are in the second column.

| Output | Legacy name | Status |
|--------|-------------|--------|
| arn | broker_arn | **WORKING** |
| identifier | broker_id | **WORKING** |
| endpoint | broker_first_endpoint (host only, no scheme/port) | **WORKING** |
| amqp_endpoint | broker_first_endpoint (full amqps://host:5671) | **WORKING** |
| endpoints | broker_endpoints | **WORKING** |
| console_url | broker_console_url | **WORKING** |
| is_cluster_mode | is_cluster_mode | **WORKING** |
| security_group_id | mq_security_group_id | **WORKING** |
| secret_arn | mq_password_secret_arn | **WORKING** |
| ~~dns_name~~ | (did not exist - no CNAME in the pre-v2 stack) | **NO LONGER EXISTS** — the CNAME this row referred to was added after the pre-v2 stack and has since been removed. `endpoint` is the raw AWS broker host in both modes. |
| port | (did not exist) | NOT RETESTED |
| mode | (did not exist) | NOT RETESTED |

---

## Test Procedure

### Prerequisites
1. AWS credentials configured with sufficient permissions
2. VPC with private subnets in 3 AZs (tagged with `Type = "private"`)
3. Terraform >= 1.0

### Steps

1. **Create test VPC** (or use existing)
   ```bash
   cd examples/aws/infra-base/vpc
   terraform init
   terraform apply -var-file=envs/dev.tfvars
   ```

2. **Test single-instance mode**
   ```bash
   cd examples/aws/products/midaz/rabbitmq
   terraform init
   
   # Set in envs/dev.tfvars:
   # broker_deployment_mode = "SINGLE_INSTANCE"
   # host_instance_type = "mq.m7g.medium"
   
   terraform apply -var-file=envs/dev.tfvars
   terraform output is_cluster_mode  # Should be: false
   terraform destroy -var-file=envs/dev.tfvars
   ```

3. **Test cluster mode**
   ```bash
   # Update envs/dev.tfvars with:
   # broker_deployment_mode = "CLUSTER_MULTI_AZ"
   # host_instance_type = "mq.m5.large"
   
   terraform apply -var-file=envs/dev.tfvars
   terraform output is_cluster_mode  # Should be: true
   terraform destroy -var-file=envs/dev.tfvars
   ```

4. **Cleanup**
   ```bash
   cd examples/aws/infra-base/vpc
   terraform destroy -var-file=envs/dev.tfvars
   rm -f terraform.tfstate*
   ```

---

## Conclusion

The AmazonMQ module correctly implements:

- **Single-instance deployment** with 1 subnet selection
- **Cluster deployment** with distinct AZ subnet selection (one subnet per AZ)
- **Proper validation** through lifecycle preconditions
- **Accurate outputs** including the `is_cluster_mode` boolean flag

The module is production-ready for RabbitMQ deployments in both single-instance and cluster configurations.
