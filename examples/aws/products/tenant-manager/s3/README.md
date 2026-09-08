# `products/tenant-manager/s3`

Two buckets: `migrations` (per-tenant SQL) and `casdoor-templates` (application
templates read during onboarding). Neither is on a money path and neither is WORM.

## The silent failure

`MIGRATIONS_S3_BUCKET` left empty does not fail the boot — it **disables the
migration handler**. A control plane that onboards tenants and never migrates them
looks healthy in every probe.

## The variable that does nothing

`CFN_TEMPLATE_S3_BUCKET` buys exactly one readiness `HeadBucket`. The
CloudFormation templates are fetched over plain HTTPS from a hardcoded **public**
URL in `sa-east-1`, bypassing the S3 SDK and IAM entirely. This root deliberately
creates no bucket for it.

## Whether you need this on day one

A product question, not an infrastructure one: it depends on whether the estate runs
per-tenant migrations through tenant-manager or lets each service run its own
migration Job. Applying it costs almost nothing; skipping it is safe.
