# `products/lerian-platform/dns`

One public hosted zone and one wildcard ACM certificate. Before this root the
foundation created **no DNS and no certificate on AWS** — `grep aws_route53` and
`grep aws_acm_certificate` both returned zero resources, the v1 route53 example was
deleted on purpose in v2, and the root README says so outright. (The support matrix
at `README.md:18` claims `infra-base` creates a DNS zone; that is true for GCP and
Azure and false for AWS.)

## Delegation, not transfer

The parent domain lives in a different AWS account. This root creates the **child**
zone here and emits its four name servers; somebody creates one NS record in the
parent. That record is the only point of contact between the two accounts, it is
reversible in minutes, and it survives an ownership transfer of this account
untouched. Transferring the domain instead moves every name already using it.

## The apply blocks, on purpose

ACM validates by resolving a record in this zone from the public internet, which
cannot happen before the parent delegates. So the apply stalls on
`aws_acm_certificate_validation` until the manual step is done, then times out.

```
1. apply -target=aws_route53_zone.this   -> read `terraform output name_servers`
2. create the NS record in the parent account, wait for propagation
3. plain apply                           -> the certificate validates
```

`wait_for_validation = false` skips the wait entirely. The certificate is still
created and still unusable until validated — check the `certificate_validated`
output, not `certificate_arn`.

## Feed `zone_arn` back into `infra-base/eks`

`external_dns_hosted_zone_arns` and `cert_manager_hosted_zone_arns` defaulted to
`arn:aws:route53:::hostedzone/*` and the prd example kept the wildcard, in the one
environment where both controllers are enabled. Narrow them to this zone.

## It installs nothing

external-dns and the AWS Load Balancer Controller are Helm releases in the next
phase; their IAM roles already exist in `infra-base/eks`. There is no cert-manager
on this estate and there need not be: TLS terminates at the ALB with this
certificate.
