# AmazonMQ Upgrade Guide: Single Instance to Cluster Mode

> **Migration note.** Migrated from the pre-v2 `examples/aws/amazonmq/docs`
> directory, removed in v2. Two things changed that matter for this procedure:
>
> 1. The AmazonMQ topology variable is now `broker_deployment_mode`, not
>    `deployment_mode`. The name `mode` is taken by the Lerian sharing contract
>    (`dedicated` / `shared`) and has nothing to do with broker topology.
> 2. There is **no DNS record in front of the broker**, and none is coming. An
>    intermediate revision of this module published a private-zone CNAME
>    (`rabbitmq.{product}.{dns_zone_name}`) and this guide used to say the CNAME
>    softened the endpoint change. That is no longer true, and the premise was
>    wrong anyway: the broker certificate covers `*.mq.<region>.on.aws`, AmazonMQ
>    exposes AMQPS only, so an alias in front of the broker fails hostname
>    verification. The endpoint churn this guide warns about is therefore real and
>    unmitigated - the broker id is part of the hostname, so a recreated broker is
>    a new host. It reaches consumers through `terraform output` (`endpoint` /
>    `amqp_endpoint`), which is how the Helm values are generated on every deploy.

## CRITICAL WARNING: Resource Recreation

**Migrating from `SINGLE_INSTANCE` to `CLUSTER_MULTI_AZ` causes RESOURCE RECREATION.**

This means:
- The existing broker will be DESTROYED
- All queues will be DELETED
- All pending messages will be LOST
- Application credentials need to be reconfigured
- A new cluster broker will be created with a new endpoint

### Why This Happens

AWS AmazonMQ does not support in-place upgrade from single-instance to cluster mode. Terraform will detect this as a resource replacement because:

1. The `broker_deployment_mode` change requires a new broker
2. The broker name changes (e.g., `midaz-dev-rabbitmq-single` to `midaz-dev-rabbitmq-cluster`)
3. The `subnet_ids` configuration changes (1 subnet to 2-3 subnets)

---

## Recommended Upgrade Procedure

**Our recommendation:** Create a NEW cluster broker alongside the existing single-instance broker, then switch traffic. Do NOT apply terraform changes directly over the existing broker.

### Prerequisites

Before starting the upgrade:

- [ ] Ensure you have at least 2-3 private subnets in DIFFERENT availability zones
- [ ] Verify the instance type is in the `mq.m5.*` / `mq.m7g.*` families — the only ones AmazonMQ offers the RabbitMQ engine, in **either** topology. `mq.t2.*` / `mq.t3.*` are ActiveMQ-only and fail `CreateBroker` in every mode. Sizing up for the cluster is optional
- [ ] Plan for brief application restart during traffic switch
- [ ] Have application deployment access ready

### Step 1: Create New Cluster Broker (Keep Single Instance Running)

**Purpose:** Create the new cluster broker without destroying the existing single-instance.

Add a second instance of this module to the product root, alongside the existing
one, and configure it for cluster mode. Because `append_deployment_suffix` puts
`-single` / `-cluster` in the broker name, the two brokers do not collide:

```hcl
# Existing single-instance broker: keep it exactly as it is.
module "rabbitmq" {
  source = "../_modules/rabbitmq-amazonmq"

  product                = "midaz"
  environment            = "dev"
  broker_deployment_mode = "SINGLE_INSTANCE"
  host_instance_type     = "mq.m7g.medium"
}

# New cluster broker. Nothing to deconflict on the DNS side - neither module
# instance creates a record. Traffic is switched by repointing the Helm values
# at the new broker's endpoint in Step 5.
module "rabbitmq_cluster" {
  source = "../_modules/rabbitmq-amazonmq"

  product                = "midaz"
  environment            = "dev"
  broker_deployment_mode = "CLUSTER_MULTI_AZ"
  host_instance_type     = "mq.m5.large"
}
```

Note: the two module instances would collide on the secret and the security
group, which are named from `module.naming.name` without the topology suffix. For
the duration of the migration, run the cluster broker from a separate root stack
(its own state and its own `product` value, e.g. `midaz-mqmig`), or import the
existing secret into the new instance. Apply the new stack:

```bash
terraform init
terraform apply -var-file=envs/dev.tfvars
```

**Expected duration:** ~10 minutes for cluster creation.

At this point you will have BOTH brokers running:
- `midaz-dev-rabbitmq-single` (existing, still serving traffic)
- `midaz-dev-rabbitmq-cluster` (new, ready to receive traffic)

### Step 2: Setup Queues and Credentials on New Cluster

**Purpose:** Prepare the new cluster with the same queue configuration.

```bash
# Get new cluster endpoint
terraform output rabbitmq_amqp_endpoint   # full amqps://host:5671 URI

# Retrieve password securely to a temporary file (not stdout/shell history)
umask 077
aws secretsmanager get-secret-value \
  --secret-id "midaz-dev-rabbitmq/password" \
  --query SecretString --output text --no-cli-pager > /tmp/mq_password.txt
chmod 600 /tmp/mq_password.txt

# Create queues on new cluster using RabbitMQ Management API
# Read password from file to avoid exposing in environment variables
curl -u "rabbitmqadmin:$(cat /tmp/mq_password.txt)" -X PUT \
  https://<new-cluster-endpoint>:15671/api/queues/%2F/your-queue-name \
  -H "content-type: application/json" \
  -d '{"durable": true}'
```

> **Security Note:** Avoid exporting secrets to environment variables (`export MQ_PASSWORD=...`) as they persist in shell history and process listings. The `/tmp/mq_password.txt` file will be used in Steps 4 and 7 - clean it up after Step 7 completes.

### Step 3: Turn Off Traffic to Midaz Application

**Purpose:** Prevent new messages from being added to queues during switch.

Disable incoming traffic to your Midaz application. The method depends on your infrastructure setup (ingress controller, load balancer, API gateway, etc.).

### Step 4: Drain Existing Queues

**Purpose:** Process all pending messages to prevent data loss.

```bash
# Monitor queue depths until empty (using credentials from temp file)
curl -u "rabbitmqadmin:$(cat /tmp/mq_password.txt)" \
  https://<old-broker-endpoint>:15671/api/queues | jq '.[] | {name, messages}'
```

**Verification:** All queues should show `messages: 0` before proceeding.

### Step 5: Switch Application to New Cluster

**Purpose:** Point the application to the new cluster broker.

Update your application's Helm values with the new cluster endpoint and credentials, then redeploy.

### Step 6: Re-enable Traffic

Re-enable incoming traffic to your Midaz application using the same method you used to disable it.

### Step 7: Verify Operation

```bash
# Check application logs for successful connections
kubectl logs -l app=midaz-app | grep -i rabbitmq

# Verify messages are being processed on new cluster
curl -u "rabbitmqadmin:$(cat /tmp/mq_password.txt)" \
  https://<new-cluster-endpoint>:15671/api/queues | jq '.[] | {name, messages}'

# Clean up: remove temporary password file after verification
rm -f /tmp/mq_password.txt
history -c  # Optional: clear shell history if password was accidentally exposed
```

### Step 8: Destroy Old Single-Instance Broker (After Stabilization)

**Purpose:** Clean up the old broker after confirming the new cluster is stable.

**Wait at least a few hours** before destroying the old broker, in case you need to rollback.

```bash
cd examples/aws/products/midaz/rabbitmq
terraform destroy -var-file=envs/dev.tfvars
```

---

## Alternative: In-Place Upgrade (NOT RECOMMENDED)

**WARNING: We strongly advise against applying this change directly over an existing AmazonMQ broker in production environments.**

If you choose to upgrade in-place:
- The existing broker will be **DESTROYED**
- All queues, messages, and configurations will be **PERMANENTLY LOST**
- There is **NO ROLLBACK** option
- Downtime is approximately **10-15 minutes**

**Use this method ONLY for non-production environments (dev, test, staging).**

**DISCLAIMER:** If you proceed with an in-place upgrade and lose RabbitMQ objects (queues, messages, bindings, etc.), this is entirely at your own risk. We are not responsible for any data loss resulting from this approach.

### Step 1: Update Terraform Variables

Update your `.tfvars` file with the following changes:

#### Terraform Variables Reference

| Variable | Single Instance | Cluster Mode | Change Required | Why |
|----------|-----------------|--------------|-----------------|-----|
| `broker_deployment_mode` | `SINGLE_INSTANCE` | `CLUSTER_MULTI_AZ` | **YES** | Enables 3-node HA cluster with automatic failover |
| `host_instance_type` | `mq.m7g.medium` or larger | Same list — any `mq.m5.*` / `mq.m7g.*` | **No** | The deployment mode does not constrain the type. RabbitMQ accepts only `mq.m5.*` / `mq.m7g.*` in **both** modes; `mq.t2.*` / `mq.t3.*` are ActiveMQ-only and fail `CreateBroker` in every mode. Size up for a production cluster because you want the capacity, not because AWS requires it. |
| `engine_type` | `RabbitMQ` or `ActiveMQ` | `RabbitMQ` only | **YES** if using ActiveMQ | ActiveMQ does not support `CLUSTER_MULTI_AZ` mode |
| `engine_version` | Any supported | Any supported | No | Same RabbitMQ versions supported |
| `name` | e.g., `midaz-dev-rabbitmq` | e.g., `midaz-dev-rabbitmq` | No | Suffix `-single` or `-cluster` auto-added by Terraform |
| `vpc_name` | VPC with 1+ private subnet | VPC with 2-3 private subnets in different AZs | **YES** if VPC lacks multi-AZ subnets | Cluster requires subnets in different AZs for HA |
| `environment` | Any | Any | No | Tag only, no functional impact |
| `mq_admin_user` | Any | Any | No | Same username works, but new password generated |
| `publicly_accessible` | `true` or `false` | `true` or `false` | No | Same behavior in both modes |
| `auto_minor_version_upgrade` | `true` or `false` | `true` or `false` | No | Recommended `true` for security patches |

#### EBS Storage Differences (AWS-managed, not configurable)

| Instance Type | Single Instance Disk | Cluster Mode Disk (per node) |
|---------------|---------------------|------------------------------|
| `mq.m7g.medium` | *not measured* | *not measured* |
| `mq.m5.large` | 200 GB | 200 GB |
| `mq.m5.xlarge` | 200 GB | 200 GB |
| `mq.m7g.large` | 200 GB | 15 GB |
| `mq.m7g.xlarge` | 200 GB | 25 GB |

**Note:** In cluster mode, data is replicated across 3 nodes, so effective storage is shared. AWS manages EBS volumes automatically - you cannot configure disk size via Terraform.

**Note:** The rows above were measured on live brokers. `mq.m7g.medium` — the smallest type the RabbitMQ engine offers, and the one the dev tfvars now use — has not been measured yet, so no figure is quoted for it. The table previously listed `mq.t3.micro` at 20 GB / "not supported"; that row was wrong on both counts, because `mq.t3.micro` is an ActiveMQ-only type that RabbitMQ rejects in **every** deployment mode.

#### Example .tfvars Changes

```hcl
# Before (Single Instance)
broker_deployment_mode = "SINGLE_INSTANCE"
host_instance_type     = "mq.m7g.medium"

# After (Cluster Mode)
broker_deployment_mode = "CLUSTER_MULTI_AZ"
host_instance_type     = "mq.m5.large"  # OPTIONAL: sizing choice, not a requirement.
                                        # mq.m7g.medium clusters just as well.
```

#### Key Constraints for Cluster Mode

1. **broker_deployment_mode**: Must be `CLUSTER_MULTI_AZ`
2. **host_instance_type**: Must be an `mq.m5.*` / `mq.m7g.*` type — the same requirement as SINGLE_INSTANCE, since the topology does not narrow the list. `mq.t2.*` / `mq.t3.*` are ActiveMQ-only and rejected in every mode. Sizing up for the cluster is a capacity decision, not an AWS constraint
3. **engine_type**: Must be `RabbitMQ` (ActiveMQ does not support cluster mode)
4. **VPC**: Must have 2-3 private subnets in DIFFERENT availability zones

### Step 2: Review Terraform Plan

```bash
cd examples/aws/products/midaz/rabbitmq
terraform plan -var-file=envs/dev.tfvars

# EXPECTED OUTPUT:
# aws_mq_broker.main will be destroyed
# aws_mq_broker.main will be created
# aws_secretsmanager_secret.mq_password will be destroyed
# aws_secretsmanager_secret.mq_password will be created
```

**Verify the plan shows resource replacement, not just update.**

### Step 3: Apply Terraform

```bash
terraform apply -var-file=envs/dev.tfvars
```

**Expected duration breakdown (based on real-world testing):**

| Phase | Duration |
|-------|----------|
| Destroy single-instance broker | ~10 seconds |
| Security group cleanup | ~1 minute |
| Create cluster broker | **~10 minutes** |
| **Total upgrade time** | **~11-12 minutes** |

**Note:** During this time, your application will have NO message broker connectivity. Plan for approximately **10-15 minutes of downtime**.

**IMPORTANT: The broker endpoint URL will change!** The broker ID is part of the endpoint URL, so when the broker is recreated, you get a completely new endpoint:

```
# Example endpoint change:
Before: amqps://b-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.mq.us-east-2.on.aws:5671
After:  amqps://b-yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy.mq.us-east-2.on.aws:5671
```

You **must** update your application configuration with the new endpoint after the upgrade completes.

### Step 4: Retrieve New Credentials and Endpoint

```bash
# Get new broker endpoint
terraform output rabbitmq_amqp_endpoint   # full amqps://host:5671 URI

# Retrieve password securely to a temporary file (not stdout/shell history)
umask 077
aws secretsmanager get-secret-value \
  --secret-id "midaz-dev-rabbitmq/password" \
  --query SecretString --output text --no-cli-pager > /tmp/mq_password.txt
chmod 600 /tmp/mq_password.txt

# Clean up after use
# rm -f /tmp/mq_password.txt && history -c
```

### Step 5: Setup Queues on New Broker

Recreate your queues on the new cluster:

```bash
# Using RabbitMQ Management API (credentials from temp file)
curl -u "rabbitmqadmin:$(cat /tmp/mq_password.txt)" -X PUT \
  https://<new-broker-endpoint>:15671/api/queues/%2F/your-queue-name \
  -H "content-type: application/json" \
  -d '{"durable": true}'
```

### Step 6: Update Application Configuration

Update your application's Helm values with the new cluster endpoint (broker host), then redeploy.

Your application must support **automatic reconnection** for cluster mode. During maintenance or failover, connections will be severed and need to be re-established.

### Step 7: Re-enable Traffic

```bash
# Scale application back up
kubectl scale deployment midaz-app --replicas=3

# Or re-enable load balancer/ingress
```

### Step 8: Verify Operation

```bash
# Check application logs for successful connections
kubectl logs -l app=midaz-app | grep -i rabbitmq

# Verify messages are being processed
curl -u "rabbitmqadmin:$(cat /tmp/mq_password.txt)" \
  https://<new-broker-endpoint>:15671/api/queues | jq '.[] | {name, messages}'
```

---

## Rollback Considerations

### If Upgrade Fails

1. **Do NOT revert Terraform immediately** - this will destroy the new cluster
2. Debug the issue first
3. If you must rollback:
   ```bash
   # Revert tfvars to single-instance
   broker_deployment_mode = "SINGLE_INSTANCE"
   host_instance_type     = "mq.m7g.medium"
   
   # Apply - WARNING: This destroys the cluster and creates a new single-instance
   terraform apply -var-file=envs/dev.tfvars
   ```

### If Application Fails to Connect

1. Verify security group allows traffic from application
2. Check the new endpoint URL is correct
3. Verify credentials are updated in application config
4. Check RabbitMQ logs in CloudWatch

---

## Testing Recommendations

### Before Production Upgrade

1. **Test in staging environment first**
   - Create a staging cluster with same configuration
   - Verify application connects successfully
   - Run load tests to verify performance

2. **Verify subnet configuration**
   ```bash
   # List private subnets and their AZs
   aws ec2 describe-subnets \
     --filters "Name=tag:Type,Values=private" \
     --query 'Subnets[*].[SubnetId,AvailabilityZone]' \
     --output table
   ```

3. **Test failover behavior**
   - Connect to cluster
   - Simulate node failure
   - Verify automatic failover works

### Acceptance Criteria

- [ ] Application connects to new cluster endpoint
- [ ] Messages are produced and consumed successfully
- [ ] No message loss detected
- [ ] Monitoring/alerting is reconfigured for new broker
- [ ] Terraform state shows healthy cluster resources

---

## Quick Reference

| Aspect | SINGLE_INSTANCE | CLUSTER_MULTI_AZ |
|--------|-----------------|------------------|
| Subnets Required | 1 | 2-3 (different AZs) |
| Instance Types | `mq.m5.*` / `mq.m7g.*` (`mq.m7g.medium` smallest) | Identical — topology does not narrow the list |
| Engine Types | ActiveMQ, RabbitMQ | RabbitMQ ONLY |
| High Availability | No | Yes |
| Automatic Failover | No | Yes |
| Typical Cost | $ | $$$ |

---

## Support

If you encounter issues during migration:

1. Check AWS CloudWatch logs for the broker
2. Review Terraform state: `terraform state show aws_mq_broker.main`
3. Contact infrastructure team with:
   - Terraform plan output
   - Application error logs
   - Broker CloudWatch logs
