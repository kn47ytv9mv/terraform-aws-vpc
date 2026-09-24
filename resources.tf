resource "aws_vpc" "resource" {
  cidr_block          = var.ipv4_ipam_pool_id == null ? var.vpc_cidr : null
  ipv4_ipam_pool_id   = var.ipv4_ipam_pool_id
  ipv4_netmask_length = var.ipv4_ipam_pool_id == null ? null : var.ipv4_netmask_length

  assign_generated_ipv6_cidr_block = var.ipv6_ipam_pool_id == null ? local.create_ipv6 : null
  ipv6_ipam_pool_id                = var.ipv6_ipam_pool_id
  ipv6_netmask_length              = var.ipv6_ipam_pool_id == null ? null : var.ipv6_netmask_length

  instance_tenancy = var.instance_tenancy

  enable_dns_hostnames                 = var.enable_dns_hostnames
  enable_dns_support                   = var.enable_dns_support
  enable_network_address_usage_metrics = var.enable_network_address_usage_metrics

  tags = merge(var.tags, { name = "vpc" })
}

resource "aws_vpc_ipv4_cidr_block_association" "resource" {
  for_each = var.secondary_cidr_blocks

  vpc_id              = aws_vpc.resource.id
  cidr_block          = each.value.cidr_block
  ipv4_ipam_pool_id   = each.value.ipv4_ipam_pool_id
  ipv4_netmask_length = each.value.ipv4_netmask_length
}

resource "aws_vpc_ipv6_cidr_block_association" "resource" {
  for_each = var.secondary_ipv6_cidr_blocks

  vpc_id              = aws_vpc.resource.id
  ipv6_cidr_block     = each.value.ipv6_cidr_block
  ipv6_pool           = each.value.ipv6_pool
  ipv6_ipam_pool_id   = each.value.ipv6_ipam_pool_id
  ipv6_netmask_length = each.value.ipv6_netmask_length
}

resource "aws_vpc_dhcp_options" "resource" {
  count = var.dhcp_options != null ? 1 : 0

  domain_name          = var.dhcp_options.domain_name
  domain_name_servers  = var.dhcp_options.domain_name_servers
  ntp_servers          = var.dhcp_options.ntp_servers
  netbios_name_servers = var.dhcp_options.netbios_name_servers
  netbios_node_type    = var.dhcp_options.netbios_node_type

  tags = var.tags
}

resource "aws_vpc_dhcp_options_association" "resource" {
  count = var.dhcp_options != null ? 1 : 0

  vpc_id          = aws_vpc.resource.id
  dhcp_options_id = aws_vpc_dhcp_options.resource[0].id
}

resource "aws_subnet" "resource" {
  for_each = local.subnets

  vpc_id                          = aws_vpc.resource.id
  availability_zone               = local.azs[each.value.az_index]
  cidr_block                      = each.value.cidr_block
  map_public_ip_on_launch         = each.value.map_public_ip_on_launch
  ipv6_cidr_block                 = each.value.ipv6_cidr_block
  assign_ipv6_address_on_creation = each.value.assign_ipv6_address_on_creation

  private_dns_hostname_type_on_launch            = each.value.private_dns_hostname_type_on_launch
  enable_resource_name_dns_a_record_on_launch    = each.value.enable_resource_name_dns_a_record_on_launch
  enable_resource_name_dns_aaaa_record_on_launch = each.value.enable_resource_name_dns_aaaa_record_on_launch

  tags = merge(var.tags, {
    name = each.key
    tier = each.value.tier_key
  }, each.value.tags)
}

resource "aws_internet_gateway" "resource" {
  count = length(local.public_tier_keys) > 0 ? 1 : 0

  vpc_id = aws_vpc.resource.id

  tags = merge(var.tags, { name = "public" })
}

resource "aws_egress_only_internet_gateway" "resource" {
  count = local.create_egress_only_igw ? 1 : 0

  vpc_id = aws_vpc.resource.id

  tags = merge(var.tags, { name = "nat" })
}

resource "aws_eip" "nat" {
  count = local.create_nat && var.nat_gateway_connectivity_type == "public" && var.nat_eip_allocation_ids == null ? local.nat_gateway_count : 0

  domain = "vpc"

  tags = merge(var.tags, { name = "nat-${count.index}" })
}

resource "aws_nat_gateway" "resource" {
  count = local.create_nat ? local.nat_gateway_count : 0

  connectivity_type = var.nat_gateway_connectivity_type
  allocation_id     = var.nat_gateway_connectivity_type == "public" ? coalesce(var.nat_eip_allocation_ids, aws_eip.nat[*].id)[count.index] : null
  subnet_id         = aws_subnet.resource["${local.nat_gateway_tier}-${count.index}"].id

  depends_on = [aws_internet_gateway.resource]

  tags = merge(var.tags, { name = "nat-${count.index}" })
}

resource "aws_route_table" "resource" {
  for_each = local.routed_subnets

  vpc_id = aws_vpc.resource.id

  propagating_vgws = each.value.propagating_vgws

  dynamic "route" {
    for_each = each.value.public ? [1] : []

    content {
      cidr_block = var.internet_cidr
      gateway_id = aws_internet_gateway.resource[0].id
    }
  }

  dynamic "route" {
    for_each = each.value.public && local.create_ipv6 ? [1] : []

    content {
      ipv6_cidr_block = var.internet_cidr_ipv6
      gateway_id      = aws_internet_gateway.resource[0].id
    }
  }

  dynamic "route" {
    for_each = !each.value.public && each.value.nat_gateway_access && local.create_nat ? [1] : []

    content {
      cidr_block     = var.internet_cidr
      nat_gateway_id = aws_nat_gateway.resource[each.value.az_index % local.nat_gateway_count].id
    }
  }

  dynamic "route" {
    for_each = !each.value.public && each.value.ipv6_egress_access && local.create_egress_only_igw ? [1] : []

    content {
      ipv6_cidr_block        = var.internet_cidr_ipv6
      egress_only_gateway_id = aws_egress_only_internet_gateway.resource[0].id
    }
  }

  dynamic "route" {
    for_each = { for idx, r in each.value.custom_routes : idx => r }

    content {
      cidr_block                = route.value.cidr_block
      ipv6_cidr_block           = route.value.ipv6_cidr_block
      gateway_id                = route.value.gateway_id
      nat_gateway_id            = route.value.nat_gateway_id
      network_interface_id      = route.value.network_interface_id
      transit_gateway_id        = route.value.transit_gateway_id
      vpc_peering_connection_id = route.value.vpc_peering_connection_id
      vpc_endpoint_id           = route.value.vpc_endpoint_id
      carrier_gateway_id        = route.value.carrier_gateway_id
      local_gateway_id          = route.value.local_gateway_id
      core_network_arn          = route.value.core_network_arn
    }
  }

  tags = merge(var.tags, { name = each.key })
}

resource "aws_route_table_association" "resource" {
  for_each = local.routed_subnets

  route_table_id = aws_route_table.resource[each.key].id
  subnet_id      = aws_subnet.resource[each.key].id
}

resource "aws_network_acl" "resource" {
  for_each = local.custom_nacl_tier_keys

  vpc_id     = aws_vpc.resource.id
  subnet_ids = [for k, s in local.subnets : aws_subnet.resource[k].id if s.tier_key == each.key]

  dynamic "ingress" {
    for_each = [for r in var.subnets[each.key].network_acl_rules : r if !r.egress]

    content {
      rule_no         = ingress.value.rule_number
      protocol        = ingress.value.protocol
      action          = ingress.value.action
      cidr_block      = ingress.value.cidr_block
      ipv6_cidr_block = ingress.value.ipv6_cidr_block
      from_port       = ingress.value.from_port
      to_port         = ingress.value.to_port
    }
  }

  dynamic "egress" {
    for_each = [for r in var.subnets[each.key].network_acl_rules : r if r.egress]

    content {
      rule_no         = egress.value.rule_number
      protocol        = egress.value.protocol
      action          = egress.value.action
      cidr_block      = egress.value.cidr_block
      ipv6_cidr_block = egress.value.ipv6_cidr_block
      from_port       = egress.value.from_port
      to_port         = egress.value.to_port
    }
  }

  tags = merge(var.tags, { name = each.key }, var.subnets[each.key].tags)
}

resource "aws_vpc_endpoint" "gateway" {
  for_each = var.gateway_endpoints

  vpc_id            = aws_vpc.resource.id
  vpc_endpoint_type = "Gateway"
  service_name      = "com.amazonaws.${data.aws_region.current.region}.${each.key}"
  route_table_ids   = local.all_route_table_ids
  policy            = each.value.policy

  tags = merge(var.tags, { name = each.key })
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.interface_endpoints

  vpc_id              = aws_vpc.resource.id
  vpc_endpoint_type   = "Interface"
  service_name        = each.value.service_name
  subnet_ids          = local.interface_endpoint_subnet_ids
  security_group_ids  = var.interface_endpoint_security_group_ids
  private_dns_enabled = each.value.private_dns_enabled
  policy              = each.value.policy

  tags = merge(var.tags, { name = each.key })
}

data "aws_iam_policy_document" "flow_log_assume" {
  count = local.create_cloud_watch_flow_log ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_log" {
  count = local.create_cloud_watch_flow_log ? 1 : 0

  assume_role_policy = data.aws_iam_policy_document.flow_log_assume[0].json

  tags = var.tags
}

resource "aws_iam_role_policy" "flow_log" {
  count = local.create_cloud_watch_flow_log ? 1 : 0

  role = aws_iam_role.flow_log[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_flow_log" "resource" {
  for_each = { for idx, f in var.flow_logs : idx => f }

  vpc_id                   = aws_vpc.resource.id
  traffic_type             = each.value.traffic_type
  log_destination_type     = each.value.destination_type
  log_destination          = each.value.destination_arn
  max_aggregation_interval = each.value.max_aggregation_interval
  log_format               = each.value.log_format
  iam_role_arn             = each.value.destination_type == "cloud-watch-logs" ? aws_iam_role.flow_log[0].arn : null

  tags = var.tags
}

resource "aws_default_security_group" "resource" {
  count = var.manage_default_security_group ? 1 : 0

  vpc_id = aws_vpc.resource.id

  tags = merge(var.tags, { name = "default" })
}

resource "aws_default_network_acl" "resource" {
  count = var.manage_default_network_acl ? 1 : 0

  default_network_acl_id = aws_vpc.resource.default_network_acl_id

  dynamic "ingress" {
    for_each = [for r in var.default_network_acl_rules : r if !r.egress]

    content {
      rule_no         = ingress.value.rule_number
      protocol        = ingress.value.protocol
      action          = ingress.value.action
      cidr_block      = ingress.value.cidr_block
      ipv6_cidr_block = ingress.value.ipv6_cidr_block
      from_port       = ingress.value.from_port
      to_port         = ingress.value.to_port
    }
  }

  dynamic "egress" {
    for_each = [for r in var.default_network_acl_rules : r if r.egress]

    content {
      rule_no         = egress.value.rule_number
      protocol        = egress.value.protocol
      action          = egress.value.action
      cidr_block      = egress.value.cidr_block
      ipv6_cidr_block = egress.value.ipv6_cidr_block
      from_port       = egress.value.from_port
      to_port         = egress.value.to_port
    }
  }

  tags = merge(var.tags, { name = "default" })
}

check "nat_requires_public_tier" {
  assert {
    condition     = length(local.nat_tier_keys) == 0 || local.nat_gateway_count == 0 || var.nat_gateway_connectivity_type == "private" || length(local.public_tier_keys) > 0
    error_message = "At least one tier must set public = true to host NAT gateways when another tier sets nat_gateway_access = true and nat_gateway_count > 0, unless nat_gateway_connectivity_type is 'private'."
  }
}

check "ipam_netmask_required" {
  assert {
    condition     = var.ipv4_ipam_pool_id == null || var.ipv4_netmask_length != null
    error_message = "ipv4_netmask_length is required when ipv4_ipam_pool_id is set."
  }
}

check "ipv6_ipam_netmask_required" {
  assert {
    condition     = var.ipv6_ipam_pool_id == null || var.ipv6_netmask_length != null
    error_message = "ipv6_netmask_length is required when ipv6_ipam_pool_id is set."
  }
}

check "nat_eip_count_matches" {
  assert {
    condition     = var.nat_eip_allocation_ids == null || length(var.nat_eip_allocation_ids) == local.nat_gateway_count
    error_message = "nat_eip_allocation_ids must have exactly one entry per NAT gateway when set."
  }
}

check "subnet_cidr_capacity" {
  assert {
    condition = alltrue([
      for specs in local.subnet_specs_by_source :
      sum([for s in specs : 1 / pow(2, s.newbits)]) <= 1
    ])
    error_message = "One or more CIDR sources (the primary CIDR, or a secondary_cidr_blocks entry) does not have enough address space for all its tiers' subnets across every availability zone at their current newbits. Raise that tier's newbits (smaller subnets, more of them available) or reduce availability_zone_count/availability_zones."
  }
}

locals {
  azs      = coalesce(var.availability_zones, slice(data.aws_availability_zones.available.names, 0, var.availability_zone_count))
  az_count = length(local.azs)

  nat_gateway_count = min(coalesce(var.nat_gateway_count, local.az_count), local.az_count)

  tier_ipv6_egress_access = { for tier_key, tier in var.subnets : tier_key => coalesce(tier.ipv6_egress_access, tier.nat_gateway_access) }

  public_tier_keys      = [for k, t in var.subnets : k if t.public]
  nat_tier_keys         = [for k, t in var.subnets : k if !t.public && t.nat_gateway_access]
  ipv6_egress_tier_keys = [for k, t in var.subnets : k if !t.public && local.tier_ipv6_egress_access[k]]

  create_nat             = local.nat_gateway_count > 0 && length(local.nat_tier_keys) > 0 && local.nat_gateway_tier != null && (var.nat_gateway_connectivity_type == "private" || length(local.public_tier_keys) > 0)
  create_ipv6            = var.enable_ipv6 || var.ipv6_ipam_pool_id != null
  create_egress_only_igw = local.create_ipv6 && length(local.ipv6_egress_tier_keys) > 0
  nat_gateway_tier       = var.nat_gateway_tier != null ? var.nat_gateway_tier : (length(local.public_tier_keys) > 0 ? local.public_tier_keys[0] : null)

  create_cloud_watch_flow_log = length([for f in var.flow_logs : f if f.destination_type == "cloud-watch-logs"]) > 0

  # AWS allows only one subnet per AZ per interface endpoint; first listed tier wins per AZ.
  interface_endpoint_subnet_ids = length(coalesce(var.interface_endpoint_subnet_tiers, [])) == 0 ? [] : compact([
    for az_index in range(local.az_count) : try(
      aws_subnet.resource[
        [
          for tier_key in var.interface_endpoint_subnet_tiers :
          "${tier_key}-${az_index}" if contains(keys(local.subnets), "${tier_key}-${az_index}")
        ][0]
      ].id,
      null
    )
  ])

  custom_nacl_tier_keys = toset([for k, t in var.subnets : k if length(t.network_acl_rules) > 0])

  all_route_table_ids = [for k, t in aws_route_table.resource : t.id]

  subnet_specs = flatten([
    for tier_key, tier in var.subnets : [
      for az_index in range(local.az_count) : {
        key                             = "${tier_key}-${az_index}"
        tier_key                        = tier_key
        az_index                        = az_index
        newbits                         = tier.newbits
        public                          = tier.public
        nat_gateway_access              = tier.nat_gateway_access
        ipv6_egress_access              = local.tier_ipv6_egress_access[tier_key]
        map_public_ip_on_launch         = coalesce(tier.map_public_ip_on_launch, tier.public)
        assign_ipv6_address_on_creation = local.create_ipv6 && (tier.public || local.tier_ipv6_egress_access[tier_key])
        cidr_source                     = tier.cidr_source
        custom_routes                   = tier.custom_routes
        propagating_vgws                = tier.propagating_vgws
        tags                            = tier.tags

        private_dns_hostname_type_on_launch            = tier.private_dns_hostname_type_on_launch
        enable_resource_name_dns_a_record_on_launch    = tier.enable_resource_name_dns_a_record_on_launch
        enable_resource_name_dns_aaaa_record_on_launch = tier.enable_resource_name_dns_aaaa_record_on_launch
      }
    ]
  ])

  subnet_specs_by_source = {
    for source_key in distinct([for s in local.subnet_specs : coalesce(s.cidr_source, "_primary")]) :
    source_key => [for s in local.subnet_specs : s if coalesce(s.cidr_source, "_primary") == source_key]
  }

  subnet_cidrs_by_source = {
    for source_key, specs in local.subnet_specs_by_source :
    source_key => cidrsubnets(
      source_key == "_primary" ? aws_vpc.resource.cidr_block : aws_vpc_ipv4_cidr_block_association.resource[source_key].cidr_block,
      specs[*].newbits...
    )
  }

  subnet_ipv6_cidrs = local.create_ipv6 ? {
    for idx, spec in local.subnet_specs : spec.key => cidrsubnet(aws_vpc.resource.ipv6_cidr_block, 8, idx)
  } : {}

  subnets = merge([
    for source_key, specs in local.subnet_specs_by_source : {
      for idx, spec in specs : spec.key => merge(spec, {
        cidr_block      = local.subnet_cidrs_by_source[source_key][idx]
        ipv6_cidr_block = lookup(local.subnet_ipv6_cidrs, spec.key, null)
      })
    }
  ]...)

  routed_subnets = {
    for k, s in local.subnets : k => s
    if s.public || s.nat_gateway_access || s.ipv6_egress_access || length(s.custom_routes) > 0 || length(s.propagating_vgws) > 0
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

output "vpc_id" {
  description = "The ID of the VPC."
  value       = aws_vpc.resource.id
}

output "vpc_cidr_block" {
  description = "IPv4 CIDR block of the VPC."
  value       = aws_vpc.resource.cidr_block
}

output "vpc_ipv6_cidr_block" {
  description = "IPv6 CIDR block of the VPC, if IPv6 is enabled."
  value       = try(aws_vpc.resource.ipv6_cidr_block, null)
}

output "availability_zones" {
  description = "Availability zones used (from availability_zones if set, otherwise the first availability_zone_count zones returned by the provider), in the order subnets were indexed against them."
  value       = local.azs
}

output "internet_gateway_id" {
  description = "The ID of the internet gateway, if any public tier was defined."
  value       = try(aws_internet_gateway.resource[0].id, null)
}

output "egress_only_internet_gateway_id" {
  description = "The ID of the egress-only internet gateway, if IPv6 is enabled and any NAT tier was defined."
  value       = try(aws_egress_only_internet_gateway.resource[0].id, null)
}

output "nat_gateway_ids" {
  description = "IDs of the NAT gateways created, if any."
  value       = aws_nat_gateway.resource[*].id
}

output "gateway_endpoint_ids" {
  description = "Map of service name to its VPC Gateway Endpoint ID."
  value       = { for k, e in aws_vpc_endpoint.gateway : k => e.id }
}

output "interface_endpoint_ids" {
  description = "Map of service name to its VPC Interface Endpoint ID."
  value       = { for k, e in aws_vpc_endpoint.interface : k => e.id }
}

output "flow_log_ids" {
  description = "IDs of the VPC flow logs created, in the order given in flow_logs."
  value       = [for k, f in aws_flow_log.resource : f.id]
}

output "dhcp_options_id" {
  description = "The ID of the custom DHCP options set, if dhcp_options was set."
  value       = try(aws_vpc_dhcp_options.resource[0].id, null)
}

output "default_security_group_id" {
  description = "The ID of the VPC's default security group, if manage_default_security_group is set."
  value       = try(aws_default_security_group.resource[0].id, null)
}

output "default_network_acl_id" {
  description = "The ID of the VPC's default network ACL, if manage_default_network_acl is set."
  value       = try(aws_default_network_acl.resource[0].id, null)
}

output "network_acl_ids" {
  description = "Map of tier name to its dedicated network ACL ID, for tiers that set network_acl_rules."
  value       = { for k, n in aws_network_acl.resource : k => n.id }
}

output "subnet_ids" {
  description = "Map of tier name to its subnet IDs, ordered by availability zone."
  value = {
    for tier_key in keys(var.subnets) : tier_key => [
      for az_index in range(local.az_count) : aws_subnet.resource["${tier_key}-${az_index}"].id
    ]
  }
}

output "subnets" {
  description = "Full map of created subnets, keyed by '<tier>-<az index>'."
  value = {
    for k, s in aws_subnet.resource : k => {
      id                = s.id
      cidr_block        = s.cidr_block
      ipv6_cidr_block   = s.ipv6_cidr_block
      availability_zone = s.availability_zone
    }
  }
}

output "route_table_ids" {
  description = "Map of subnet key ('<tier>-<az index>') to its explicit route table ID. Fully isolated tiers (no public, nat_gateway_access, ipv6_egress_access, custom_routes, or propagating_vgws) use the VPC's default route table and are omitted here."
  value       = { for k, t in aws_route_table.resource : k => t.id }
}
