# terraform-aws-vpc

Terraform module for a general-purpose VPC with an arbitrary number of subnet
tiers (public, private, database, or anything else), spread across a
configurable number of availability zones, with sensible defaults out of the
box: a public tier routed through an internet gateway and a private tier
routed through one NAT gateway per availability zone.

## Cost

The VPC, subnets, and route tables carry no charge. NAT gateways do:
each one bills hourly for as long as it exists, plus a per-gigabyte data
processing charge, regardless of traffic volume. This module creates one
NAT gateway per availability zone by default wherever a tier requests
NAT access — set `nat_gateway_count = 0` to avoid this charge entirely.
See AWS's [VPC pricing](https://aws.amazon.com/vpc/pricing/) page for
current rates.

## Design

Subnet layout is entirely driven by the `subnets` map — there is no fixed
notion of "public" or "private" baked into the module itself:

- Each key in `subnets` is a tier name. One subnet per tier per availability
  zone is created, sized by that tier's `newbits` (default `8`, e.g. a `/24`
  in a `/16` VPC) and packed into the VPC CIDR with `cidrsubnets`, so tiers
  never overlap regardless of how many are defined or how they are sized.
- A tier with `public = true` gets a route to the internet gateway.
- A tier with `nat_gateway_access = true` gets a route to the NAT gateway in
  its own availability zone.
- A tier with neither set is fully isolated — it stays on the VPC's default
  route table, with no route out of the VPC. Useful for database or
  intra-only tiers.
- IPv6 egress normally follows `nat_gateway_access`, but a tier can set
  `ipv6_egress_access` explicitly to decouple the two.
- Each tier accepts its own `tags`, merged on top of the module-wide `tags`
  variable, for tags that must live on specific subnets (Kubernetes
  subnet-discovery tags, for example).
- Each tier can also set its own subnet-level DNS hostname behavior
  (`private_dns_hostname_type_on_launch` and the resource-name DNS record
  toggles), independent of every other tier.

CIDR allocation can come from a plain `vpc_cidr`, or from an AWS VPC IPAM pool
via `ipv4_ipam_pool_id` (and `ipv6_ipam_pool_id` for IPv6) — pair this module
with [`terraform-aws-ipam`](https://github.com/kn47ytv9mv/terraform-aws-ipam),
which hands each region a non-overlapping pool ID, the mechanism that makes
peering or a transit gateway between VPCs in different regions actually work.

## Usage

```hcl
module "vpc" {
  source = "kn47ytv9mv/vpc/aws"
}
```

Or directly from this repository:

```hcl
module "vpc" {
  source = "github.com/kn47ytv9mv/terraform-aws-vpc"
}
```

A three-tier VPC with an isolated database tier and no default NAT for it:

```hcl
module "vpc" {
  source = "kn47ytv9mv/vpc/aws"

  availability_zone_count = 3

  subnets = {
    public = {
      newbits = 4
      public  = true
    }
    private = {
      newbits            = 4
      nat_gateway_access = true
    }
    database = {
      newbits = 8
    }
  }
}
```

## Examples

Each example below demonstrates one architecture this module supports. Click a
title to expand it.

<details>
<summary>Fully isolated VPC, no internet egress anywhere</summary>

Every tier stays off the internet entirely. The `app` tier reaches an
on-premises network only through a
[`terraform-aws-transit-gateway`](https://github.com/kn47ytv9mv/terraform-aws-transit-gateway)
attachment; nothing in this VPC has a route to `0.0.0.0/0`.

```hcl
module "vpc" {
  source = "kn47ytv9mv/vpc/aws"

  subnets = {
    app = {
      newbits = 4
      custom_routes = [{
        cidr_block         = "10.100.0.0/16"
        transit_gateway_id = module.transit_gateway.id
      }]
    }
    data = {
      newbits = 8
    }
  }
}
```

</details>

<details>
<summary>Cost-optimized private AWS connectivity, no NAT gateway</summary>

A private-only tier reaches S3, DynamoDB, and a handful of other AWS
services entirely through VPC endpoints, skipping NAT gateway hourly and
data-processing charges altogether.

```hcl
module "vpc" {
  source = "kn47ytv9mv/vpc/aws"

  subnets = {
    private = {
      newbits = 4
    }
  }

  nat_gateway_count = 0

  gateway_endpoints = {
    s3       = {}
    dynamodb = {}
  }

  interface_endpoints = {
    ssm            = { service_name = "com.amazonaws.us-east-1.ssm" }
    secretsmanager = { service_name = "com.amazonaws.us-east-1.secretsmanager" }
    ecr_api        = { service_name = "com.amazonaws.us-east-1.ecr.api" }
  }
  interface_endpoint_subnet_tiers = ["private"]
}
```

</details>

<details>
<summary>EKS-ready subnet tagging</summary>

Per-tier `tags` carry the Kubernetes subnet-discovery tags the AWS Load
Balancer Controller and Karpenter look for, without adding them to every
resource in the VPC via the module-wide `tags` variable.

```hcl
module "vpc" {
  source = "kn47ytv9mv/vpc/aws"

  subnets = {
    public = {
      newbits = 4
      public  = true
      tags    = { "kubernetes.io/role/elb" = "1" }
    }
    private = {
      newbits            = 4
      nat_gateway_access = true
      tags = {
        "kubernetes.io/role/internal-elb" = "1"
        "kubernetes.io/cluster/example"   = "shared"
      }
    }
  }
}
```

</details>

<details>
<summary>IPv6 dual-stack with a NAT-free IPv6 egress tier</summary>

`ipv6_only_egress` gets outbound IPv6 through the egress-only internet
gateway without ever setting `nat_gateway_access` — IPv6 egress is
decoupled from IPv4 NAT, so this tier never pays for a NAT gateway.

```hcl
module "vpc" {
  source = "kn47ytv9mv/vpc/aws"

  enable_ipv6 = true

  subnets = {
    public = {
      newbits = 4
      public  = true
    }
    private = {
      newbits            = 4
      nat_gateway_access = true
    }
    ipv6_only_egress = {
      newbits            = 4
      ipv6_egress_access = true
    }
  }
}
```

</details>

<details>
<summary>Flow logs paired with terraform-aws-cloudwatch-log-group</summary>

This module does not create the destination log group itself — pair it
with a sibling module, the same standalone-over-composed pattern used
throughout this family.

```hcl
module "flow_log_group" {
  source = "kn47ytv9mv/cloudwatch-log-group/aws"

  name              = "vpc-flow-logs"
  retention_in_days = 90
}

module "vpc" {
  source = "kn47ytv9mv/vpc/aws"

  flow_logs = [{
    destination_arn = module.flow_log_group.arn
  }]
}
```

</details>

<details>
<summary>Private NAT gateway for hybrid/on-premises connectivity</summary>

A `'private'` NAT gateway has no public IP and never touches the
internet — useful for translating addresses between private subnet
segments reachable from an on-premises network, without any internet
exposure at all.

```hcl
module "vpc" {
  source = "kn47ytv9mv/vpc/aws"

  subnets = {
    private = {
      newbits            = 4
      nat_gateway_access = true
    }
  }

  nat_gateway_connectivity_type = "private"
  nat_gateway_tier              = "private"
}
```

</details>

<details>
<summary>Secondary CIDR block with per-tier carving</summary>

The `burst` tier's subnets are carved from a secondary CIDR block instead
of the VPC's primary one, for when the primary CIDR does not have enough
room left for a new tier.

```hcl
module "vpc" {
  source = "kn47ytv9mv/vpc/aws"

  vpc_cidr = "10.0.0.0/16"

  secondary_cidr_blocks = {
    overflow = {
      cidr_block = "10.1.0.0/16"
    }
  }

  subnets = {
    public = {
      newbits = 4
      public  = true
    }
    private = {
      newbits            = 4
      nat_gateway_access = true
    }
    burst = {
      newbits     = 4
      cidr_source = "overflow"
    }
  }
}
```

</details>

## Requirements

| Name | Version |
|---|---|
| terraform | >= 1.9 |
| aws | ~> 6.61 |

## Providers

| Name | Version |
|---|---|
| aws | ~> 6.61 |

## Inputs

| Name | Description | Default | Required |
|---|---|---|---|
| vpc_cidr | IPv4 CIDR block for the VPC. Ignored if `ipv4_ipam_pool_id` is set. | `"10.0.0.0/16"` | no |
| ipv4_ipam_pool_id | The ID of an IPAM pool to allocate the VPC's primary CIDR from. When set, `vpc_cidr` is ignored and `ipv4_netmask_length` is required. | `null` | no |
| ipv4_netmask_length | Netmask length to request from `ipv4_ipam_pool_id`. Required when `ipv4_ipam_pool_id` is set. | `null` | no |
| secondary_cidr_blocks | Additional IPv4 CIDR blocks to associate with the VPC, keyed by an arbitrary name. Each entry needs either `cidr_block`, or `ipv4_ipam_pool_id` (with `ipv4_netmask_length`). Reference a key from a tier's `cidr_source` (in `subnets`) to carve that tier's subnets out of it instead of the VPC's primary CIDR. | `{}` | no |
| instance_tenancy | Tenancy option for instances launched into the VPC (`'default'` or `'dedicated'`). | `"default"` | no |
| enable_ipv6 | Whether to assign an Amazon-provided `/56` IPv6 CIDR block to the VPC. Ignored if `ipv6_ipam_pool_id` is set. Each subnet then gets a `/64` carved from it; see [Design](#design) for how tiers route it. | `false` | no |
| secondary_ipv6_cidr_blocks | Additional IPv6 CIDR blocks to associate with the VPC, keyed by an arbitrary name. Each entry needs either `ipv6_cidr_block` (a BYOIP CIDR, with `ipv6_pool`) or `ipv6_ipam_pool_id` (with `ipv6_netmask_length`). Association only — subnets are not carved from these. | `{}` | no |
| ipv6_ipam_pool_id | The ID of an IPAM pool to allocate the VPC's IPv6 CIDR from, instead of an Amazon-provided block. When set, `enable_ipv6` is ignored (treated as true) and `ipv6_netmask_length` is required. | `null` | no |
| ipv6_netmask_length | Netmask length to request from `ipv6_ipam_pool_id`. Required when `ipv6_ipam_pool_id` is set. | `null` | no |
| availability_zone_count | Number of availability zones to spread subnets across, taking the first N zones the provider returns. Ignored if `availability_zones` is set. | `2` | no |
| availability_zones | Explicit availability zones to spread subnets across, overriding `availability_zone_count`. Use this to pin specific zones instead of relying on provider API order. | `null` | no |
| subnets | Map of subnet tiers to create, keyed by an arbitrary tier name. See [Design](#design). | `{ public = { public = true }, private = { nat_gateway_access = true } }` | no |
| nat_gateway_count | Number of NAT gateways to create, one per availability zone up to this count. Defaults to one per availability zone. Set to `0` to disable NAT entirely. | `null` | no |
| nat_gateway_tier | Tier (key into `subnets`) that hosts the NAT gateways. Must be a tier with `public = true` when `nat_gateway_connectivity_type` is `'public'` (the default). If null, the first public tier is used; required (no default) when `nat_gateway_connectivity_type` is `'private'`. | `null` | no |
| nat_eip_allocation_ids | Existing Elastic IP allocation IDs for public NAT gateways, instead of allocating new ones. Must have exactly one entry per NAT gateway when set. Ignored when `nat_gateway_connectivity_type` is `'private'`. | `null` | no |
| nat_gateway_connectivity_type | Connectivity type for the NAT gateways (`'public'` or `'private'`). A `'public'` NAT gateway gets an Elastic IP and provides internet egress. A `'private'` NAT gateway has no public IP and routes only within the VPC or to an on-premises network via Transit Gateway. | `"public"` | no |
| internet_cidr | Destination CIDR routed to the internet gateway and NAT gateways. | `"0.0.0.0/0"` | no |
| internet_cidr_ipv6 | Destination IPv6 CIDR routed to the internet gateway and egress-only internet gateway. | `"::/0"` | no |
| gateway_endpoints | VPC Gateway Endpoints to create, keyed by AWS service name. AWS supports exactly two: `'s3'` and `'dynamodb'`. Each entry's `policy` is optional; if null, AWS's default (full access) policy applies. Associated with every route table this module creates, at no additional AWS charge, so traffic to these services skips NAT gateway data processing charges entirely. | `{}` | no |
| interface_endpoints | VPC Interface Endpoints to create, keyed by an arbitrary name. Each entry needs `service_name` — an AWS service's full name (e.g. `'com.amazonaws.us-east-1.secretsmanager'`) or a custom PrivateLink service name (e.g. `'com.amazonaws.vpce.us-east-1.vpce-svc-0123456789abcdef0'`). `policy` and `private_dns_enabled` (default `true`) are optional. Unlike gateway endpoints, these are ENI-based and bill hourly plus per-gigabyte. Requires `interface_endpoint_subnet_tiers`. | `{}` | no |
| interface_endpoint_subnet_tiers | Tiers (keys into `subnets`) whose subnets host interface endpoint ENIs, in priority order. Required if `interface_endpoints` is non-empty. AWS allows only one subnet per availability zone per endpoint, so if more than one listed tier has a subnet in the same zone, the first tier in this list is used for that zone. | `null` | no |
| interface_endpoint_security_group_ids | IDs of the security groups to associate with interface endpoint ENIs. If null, the VPC's default security group is used. | `null` | no |
| flow_logs | VPC flow logs to create. Each entry needs `destination_arn` (a CloudWatch Logs group or S3 bucket ARN); `destination_type` defaults to `'cloud-watch-logs'` (or `'s3'`), `traffic_type` defaults to `'ALL'`, `max_aggregation_interval` defaults to `600` seconds (AWS supports only `60` or `600`), and `log_format` defaults to AWS's own default fields. Pair a `cloud-watch-logs` destination with `terraform-aws-cloudwatch-log-group`. | `[]` | no |
| dhcp_options | Custom DHCP options for the VPC (`domain_name`, `domain_name_servers`, `ntp_servers`, `netbios_name_servers`, `netbios_node_type`, all optional). If null, AWS's default DHCP options set is used. | `null` | no |
| enable_dns_hostnames | Whether DNS hostnames are enabled for the VPC. | `true` | no |
| enable_dns_support | Whether DNS resolution is enabled for the VPC. | `true` | no |
| enable_network_address_usage_metrics | Whether to publish Network Address Usage metrics for the VPC to CloudWatch. | `false` | no |
| manage_default_security_group | Whether to take over the VPC's default security group and strip it of every rule, so nothing uses it by accident. Set to false to leave AWS's permissive default (allow-all within the group) in place. | `true` | no |
| manage_default_network_acl | Whether to take over the VPC's default network ACL. Defaults to false, unlike `manage_default_security_group`: every subnet without its own tier-level `network_acl_rules` uses the default one, so stripping its rules with no replacement blocks all traffic for that subnet unless `default_network_acl_rules` supplies one. | `false` | no |
| default_network_acl_rules | Rules for the default network ACL, applied only if `manage_default_network_acl` is true. Each entry needs `rule_number`, `egress` (bool), `protocol`, `action` (`'allow'` or `'deny'`), one of `cidr_block` or `ipv6_cidr_block`, and optional `from_port`/`to_port`. | `[]` | no |
| tags | A map of tags to assign to all resources created by this module. | `null` | no |

## Outputs

| Name | Description |
|---|---|
| vpc_id | The ID of the VPC. |
| vpc_cidr_block | The IPv4 CIDR block of the VPC. |
| vpc_ipv6_cidr_block | The IPv6 CIDR block of the VPC, if IPv6 is enabled. |
| availability_zones | The availability zones used (from `availability_zones` if set, otherwise the first `availability_zone_count` zones returned by the provider), in the order subnets were indexed against them. |
| internet_gateway_id | The ID of the internet gateway, if any public tier was defined. |
| egress_only_internet_gateway_id | The ID of the egress-only internet gateway, if IPv6 is enabled and any NAT tier was defined. |
| nat_gateway_ids | The IDs of the NAT gateways created, if any. |
| gateway_endpoint_ids | Map of service name to its VPC Gateway Endpoint ID. |
| interface_endpoint_ids | Map of service name to its VPC Interface Endpoint ID. |
| flow_log_ids | The IDs of the VPC flow logs created, in the order given in `flow_logs`. |
| dhcp_options_id | The ID of the custom DHCP options set, if `dhcp_options` was set. |
| default_security_group_id | The ID of the VPC's default security group, if `manage_default_security_group` is set. |
| default_network_acl_id | The ID of the VPC's default network ACL, if `manage_default_network_acl` is set. |
| network_acl_ids | Map of tier name to its dedicated network ACL ID, for tiers that set `network_acl_rules`. |
| subnet_ids | Map of tier name to its subnet IDs, ordered by availability zone. |
| subnets | Full map of created subnets, keyed by `"<tier>-<az index>"`. |
| route_table_ids | Map of subnet key to its explicit route table ID. Fully isolated tiers (no `public`, `nat_gateway_access`, `ipv6_egress_access`, `custom_routes`, or `propagating_vgws`) are omitted. |

## License

MIT — see [LICENSE.md](LICENSE.md).
