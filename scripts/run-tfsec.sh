#!/bin/bash

# Run tfsec with specific exclusions
tfsec ./examples/aws \
  --exclude aws-ec2-no-public-egress-sgr,aws-ec2-require-vpc-flow-logs-for-all-vpcs \
  "$@"  # Pass any additional arguments to tfsec
