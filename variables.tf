variable "vpc_cidr" {
  default     = "10.0.0.0/16"
  description = "IPv4 CIDR block for the VPC. Ignored if ipv4_ipam_pool_id is set."
}

variable "ipv4_ipam_pool_id" {
  default     = null
  description = "The ID of an IPAM pool to allocate the VPC's primary CIDR from. When set, vpc_cidr is ignored and ipv4_netmask_length is required."
}

variable "ipv4_netmask_length" {
  default     = null
  description = "Netmask length to request from ipv4_ipam_pool_id. Required when ipv4_ipam_pool_id is set."
}

variable "secondary_cidr_blocks" {
  default     = {}
  description = "Additional IPv4 CIDR blocks to associate with the VPC, keyed by an arbitrary name. Each entry needs either cidr_block, or ipv4_ipam_pool_id (with ipv4_netmask_length). Reference a key from a tier's cidr_source (in the subnets map) to carve that tier's subnets out of it instead of the VPC's primary CIDR."
  type = map(object({
    cidr_block          = optional(string)
    ipv4_ipam_pool_id   = optional(string)
    ipv4_netmask_length = optional(number)
  }))

  validation {
    condition = alltrue([
      for k, c in var.secondary_cidr_blocks : (c.cidr_block != null) != (c.ipv4_ipam_pool_id != null)
    ])
    error_message = "Each secondary_cidr_blocks entry needs exactly one of cidr_block or ipv4_ipam_pool_id."
  }
}

variable "instance_tenancy" {
  default     = "default"
  description = "Tenancy option for instances launched into the VPC ('default' or 'dedicated')."

  validation {
    condition     = contains(["default", "dedicated"], var.instance_tenancy)
    error_message = "instance_tenancy must be 'default' or 'dedicated'."
  }
}

variable "enable_ipv6" {
  default     = false
  description = "Whether to assign an Amazon-provided /56 IPv6 CIDR block to the VPC. Ignored if ipv6_ipam_pool_id is set. Each subnet then gets a /64 carved from it; see the subnets variable for how tiers route it."
}

variable "secondary_ipv6_cidr_blocks" {
  default     = {}
  description = "Additional IPv6 CIDR blocks to associate with the VPC, keyed by an arbitrary name. Each entry needs either ipv6_cidr_block (a BYOIP CIDR, with ipv6_pool) or ipv6_ipam_pool_id (with ipv6_netmask_length). Association only — subnets are not carved from these."
  type = map(object({
    ipv6_cidr_block     = optional(string)
    ipv6_pool           = optional(string)
    ipv6_ipam_pool_id   = optional(string)
    ipv6_netmask_length = optional(number)
  }))

  validation {
    condition = alltrue([
      for k, c in var.secondary_ipv6_cidr_blocks : (c.ipv6_cidr_block != null) != (c.ipv6_ipam_pool_id != null)
    ])
    error_message = "Each secondary_ipv6_cidr_blocks entry needs exactly one of ipv6_cidr_block or ipv6_ipam_pool_id."
  }
}

variable "ipv6_ipam_pool_id" {
  default     = null
  description = "The ID of an IPAM pool to allocate the VPC's IPv6 CIDR from, instead of an Amazon-provided block. When set, enable_ipv6 is ignored (treated as true) and ipv6_netmask_length is required."
}

variable "ipv6_netmask_length" {
  default     = null
  description = "Netmask length to request from ipv6_ipam_pool_id. Required when ipv6_ipam_pool_id is set."
}

variable "availability_zone_count" {
  default     = 2
  description = "Number of availability zones to spread subnets across, taking the first N zones the provider returns. Ignored if availability_zones is set."
}

variable "availability_zones" {
  default     = null
  description = "Explicit availability zones to spread subnets across, overriding availability_zone_count. Use this to pin specific zones instead of relying on provider API order."

  validation {
    condition     = var.availability_zones == null || length(var.availability_zones) > 0
    error_message = "availability_zones must not be an empty list when set — omit the variable entirely (leave it null) to use availability_zone_count instead."
  }
}

variable "subnets" {
  default = {
    public = {
      public = true
    }
    private = {
      nat_gateway_access = true
    }
  }

  description = <<-EOT
    Map of subnet tiers to create, keyed by an arbitrary tier name (e.g. "public", "private",
    "database"). One subnet is created per tier per availability zone. Each tier supports:
      - newbits: additional bits for the subnet CIDR, relative to the CIDR it is carved from
        (default 8, i.e. a /24 in a /16 VPC).
      - public: whether the tier's subnets route 0.0.0.0/0 to the internet gateway (default false).
      - nat_gateway_access: whether the tier's subnets route 0.0.0.0/0 to a NAT gateway in the same
        availability zone (default false; ignored when public is true).
      - ipv6_egress_access: whether the tier's subnets route ::/0 to the egress-only internet
        gateway (default null, following nat_gateway_access — set explicitly to decouple IPv6
        egress from IPv4 NAT).
      - map_public_ip_on_launch: whether instances launched in the tier get a public IP
        automatically (defaults to the tier's public value).
      - cidr_source: key into secondary_cidr_blocks to carve this tier's subnets from that CIDR
        instead of the VPC's primary one (default null, i.e. the primary CIDR).
      - custom_routes: additional routes for the tier's route table (list of objects with a
        destination — cidr_block or ipv6_cidr_block — and exactly one target: gateway_id,
        nat_gateway_id, network_interface_id, transit_gateway_id, vpc_peering_connection_id,
        vpc_endpoint_id, carrier_gateway_id, local_gateway_id, or core_network_arn). Gives a tier a
        route table even if it sets neither public nor nat_gateway_access.
      - propagating_vgws: IDs of externally-created VPN Gateways to propagate routes from into this
        tier's route table (default []). The module does not create the VPN Gateway itself.
      - network_acl_rules: rules for a network ACL dedicated to this tier (same shape as
        default_network_acl_rules). If empty (the default), the tier's subnets stay on the VPC's
        default network ACL instead of getting their own.
      - tags: extra tags merged onto just this tier's subnets (and its dedicated network ACL, if
        network_acl_rules is set), in addition to the module-wide tags variable. Use this for tags
        that must live on specific subnets rather than the whole VPC, e.g. Kubernetes/Karpenter
        subnet-discovery tags (kubernetes.io/role/elb, kubernetes.io/cluster/<name>).
      - private_dns_hostname_type_on_launch: DNS hostname type for instances launched in the tier
        ('ip-name' or 'resource-name'; default null, i.e. AWS's own default).
      - enable_resource_name_dns_a_record_on_launch / enable_resource_name_dns_aaaa_record_on_launch:
        whether instances get an A/AAAA record using their resource-name-based hostname (default
        null, i.e. AWS's own default).
    Tiers that set none of public, nat_gateway_access, ipv6_egress_access, custom_routes, or
    propagating_vgws are fully isolated: they stay on the VPC's default route table, with no route
    out of the VPC.
  EOT
  type = map(object({
    newbits                                        = optional(number, 8)
    public                                         = optional(bool, false)
    nat_gateway_access                             = optional(bool, false)
    ipv6_egress_access                             = optional(bool)
    map_public_ip_on_launch                        = optional(bool)
    cidr_source                                    = optional(string)
    propagating_vgws                               = optional(list(string), [])
    tags                                           = optional(map(string), {})
    private_dns_hostname_type_on_launch            = optional(string)
    enable_resource_name_dns_a_record_on_launch    = optional(bool)
    enable_resource_name_dns_aaaa_record_on_launch = optional(bool)
    custom_routes = optional(list(object({
      cidr_block                = optional(string)
      ipv6_cidr_block           = optional(string)
      gateway_id                = optional(string)
      nat_gateway_id            = optional(string)
      network_interface_id      = optional(string)
      transit_gateway_id        = optional(string)
      vpc_peering_connection_id = optional(string)
      vpc_endpoint_id           = optional(string)
      carrier_gateway_id        = optional(string)
      local_gateway_id          = optional(string)
      core_network_arn          = optional(string)
    })), [])
    network_acl_rules = optional(list(object({
      rule_number     = number
      egress          = bool
      protocol        = string
      action          = string
      cidr_block      = optional(string)
      ipv6_cidr_block = optional(string)
      from_port       = optional(number, 0)
      to_port         = optional(number, 0)
    })), [])
  }))

  validation {
    condition = alltrue(flatten([
      for tier_key, tier in var.subnets : [
        for r in tier.custom_routes : (
          (r.cidr_block != null) != (r.ipv6_cidr_block != null)
          ) && (
          length([for t in [
            r.gateway_id, r.nat_gateway_id, r.network_interface_id, r.transit_gateway_id,
            r.vpc_peering_connection_id, r.vpc_endpoint_id, r.carrier_gateway_id,
            r.local_gateway_id, r.core_network_arn
          ] : t if t != null]) == 1
        )
      ]
    ]))
    error_message = "Each tier's custom_routes entries need exactly one destination (cidr_block or ipv6_cidr_block) and exactly one target."
  }

  validation {
    condition = alltrue(flatten([
      for tier_key, tier in var.subnets : [
        for r in tier.network_acl_rules : (
          (r.cidr_block != null) != (r.ipv6_cidr_block != null)
        ) && contains(["allow", "deny"], r.action)
      ]
    ]))
    error_message = "Each tier's network_acl_rules entries need exactly one of cidr_block or ipv6_cidr_block, and action must be 'allow' or 'deny'."
  }

  validation {
    condition = alltrue([
      for tier_key, tier in var.subnets : (
        tier.private_dns_hostname_type_on_launch == null ||
        contains(["ip-name", "resource-name"], tier.private_dns_hostname_type_on_launch)
      )
    ])
    error_message = "Each tier's private_dns_hostname_type_on_launch must be 'ip-name' or 'resource-name' when set."
  }

  validation {
    condition = alltrue([
      for tier_key, tier in var.subnets : tier.cidr_source == null || contains(keys(var.secondary_cidr_blocks), tier.cidr_source)
    ])
    error_message = "Every tier's cidr_source must be a key in secondary_cidr_blocks."
  }
}

variable "nat_gateway_count" {
  default     = null
  description = "Number of NAT gateways to create, one per availability zone up to this count. Defaults to one per availability zone. Set to 0 to disable NAT entirely; tiers with nat_gateway_access = true then have no internet route."
}

variable "nat_gateway_tier" {
  default     = null
  description = "Tier (key into subnets) that hosts the NAT gateways. Must be a tier with public = true when nat_gateway_connectivity_type is 'public' (the default). If null, the first public tier is used; required (no default) when nat_gateway_connectivity_type is 'private'."

  validation {
    condition     = var.nat_gateway_tier == null || contains(keys(var.subnets), var.nat_gateway_tier)
    error_message = "nat_gateway_tier must be a key in subnets when set."
  }

  validation {
    condition = (
      var.nat_gateway_connectivity_type == "private" ||
      var.nat_gateway_tier == null ||
      !contains(keys(var.subnets), var.nat_gateway_tier) ||
      var.subnets[var.nat_gateway_tier].public
    )
    error_message = "nat_gateway_tier must be a tier with public = true when nat_gateway_connectivity_type is 'public'."
  }

  validation {
    condition     = var.nat_gateway_connectivity_type != "private" || var.nat_gateway_tier != null
    error_message = "nat_gateway_tier must be set explicitly when nat_gateway_connectivity_type is 'private' — there is no default to fall back to."
  }
}

variable "nat_eip_allocation_ids" {
  default     = null
  description = "Existing Elastic IP allocation IDs for public NAT gateways, instead of allocating new ones — e.g. to keep an IP a partner has allowlisted. Must have exactly one entry per NAT gateway when set. Ignored when nat_gateway_connectivity_type is 'private'."
}

variable "nat_gateway_connectivity_type" {
  default     = "public"
  description = "Connectivity type for the NAT gateways ('public' or 'private'). A 'public' NAT gateway gets an Elastic IP and provides internet egress. A 'private' NAT gateway has no public IP and routes only within the VPC or to an on-premises network via Transit Gateway."

  validation {
    condition     = contains(["public", "private"], var.nat_gateway_connectivity_type)
    error_message = "nat_gateway_connectivity_type must be 'public' or 'private'."
  }
}

variable "internet_cidr" {
  default     = "0.0.0.0/0"
  description = "Destination CIDR routed to the internet gateway and NAT gateways."
}

variable "internet_cidr_ipv6" {
  default     = "::/0"
  description = "Destination IPv6 CIDR routed to the internet gateway and egress-only internet gateway."
}

variable "gateway_endpoints" {
  default     = {}
  description = "VPC Gateway Endpoints to create, keyed by AWS service name. AWS supports exactly two: 's3' and 'dynamodb'. Each entry's policy is optional; if null, AWS's default (full access) policy applies. Associated with every route table this module creates, at no additional AWS charge, so traffic to these services skips NAT gateway data processing charges entirely."
  type = map(object({
    policy = optional(string)
  }))
}

variable "interface_endpoints" {
  default     = {}
  description = "VPC Interface Endpoints to create, keyed by an arbitrary name. Each entry needs service_name — an AWS service's full name (e.g. 'com.amazonaws.us-east-1.secretsmanager') or a custom PrivateLink service name (e.g. 'com.amazonaws.vpce.us-east-1.vpce-svc-0123456789abcdef0'). policy and private_dns_enabled (default true) are optional. Unlike gateway endpoints, these are ENI-based and bill hourly plus per-gigabyte. Requires interface_endpoint_subnet_tiers."
  type = map(object({
    service_name        = string
    policy              = optional(string)
    private_dns_enabled = optional(bool, true)
  }))
}

variable "interface_endpoint_subnet_tiers" {
  default     = null
  description = "Tiers (keys into subnets) whose subnets host interface endpoint ENIs, in priority order. Required if interface_endpoints is non-empty. AWS allows only one subnet per availability zone per endpoint, so if more than one listed tier has a subnet in the same zone, the first tier in this list is used for that zone."

  validation {
    condition = length(var.interface_endpoints) == 0 || (
      var.interface_endpoint_subnet_tiers != null &&
      length(var.interface_endpoint_subnet_tiers) > 0 &&
      alltrue([for t in var.interface_endpoint_subnet_tiers : contains(keys(var.subnets), t)])
    )
    error_message = "interface_endpoint_subnet_tiers must be a non-empty list of keys in subnets when interface_endpoints is non-empty."
  }
}

variable "interface_endpoint_security_group_ids" {
  default     = null
  description = "IDs of the security groups to associate with interface endpoint ENIs. If null, the VPC's default security group is used."
}

variable "flow_logs" {
  default     = []
  description = "VPC flow logs to create. Each entry needs destination_arn (a CloudWatch Logs group or S3 bucket ARN); destination_type defaults to 'cloud-watch-logs' (or 's3'), traffic_type defaults to 'ALL', max_aggregation_interval defaults to 600 seconds (AWS supports only 60 or 600), and log_format defaults to AWS's own default fields. Pair a cloud-watch-logs destination with terraform-aws-cloudwatch-log-group."
  type = list(object({
    destination_arn          = string
    destination_type         = optional(string, "cloud-watch-logs")
    traffic_type             = optional(string, "ALL")
    max_aggregation_interval = optional(number, 600)
    log_format               = optional(string)
  }))

  validation {
    condition     = alltrue([for f in var.flow_logs : contains(["cloud-watch-logs", "s3"], f.destination_type)])
    error_message = "Each flow_logs entry's destination_type must be 'cloud-watch-logs' or 's3'."
  }

  validation {
    condition     = alltrue([for f in var.flow_logs : contains(["ACCEPT", "REJECT", "ALL"], f.traffic_type)])
    error_message = "Each flow_logs entry's traffic_type must be 'ACCEPT', 'REJECT', or 'ALL'."
  }

  validation {
    condition     = alltrue([for f in var.flow_logs : contains([60, 600], f.max_aggregation_interval)])
    error_message = "Each flow_logs entry's max_aggregation_interval must be 60 or 600 (AWS's only supported values)."
  }
}

variable "dhcp_options" {
  default     = null
  description = "Custom DHCP options for the VPC. If null, AWS's default DHCP options set is used (Amazon-provided DNS, no custom domain or NTP). Every field is optional; set only what you need to override."
  type = object({
    domain_name          = optional(string)
    domain_name_servers  = optional(list(string))
    ntp_servers          = optional(list(string))
    netbios_name_servers = optional(list(string))
    netbios_node_type    = optional(string)
  })
}

variable "enable_dns_hostnames" {
  default     = true
  description = "Whether DNS hostnames are enabled for the VPC."
}

variable "enable_dns_support" {
  default     = true
  description = "Whether DNS resolution is enabled for the VPC."
}

variable "enable_network_address_usage_metrics" {
  default     = false
  description = "Whether to publish Network Address Usage metrics for the VPC to CloudWatch, to track usage against the account's NAU quota."
}

variable "manage_default_security_group" {
  default     = true
  description = "Whether to take over the VPC's default security group and strip it of every rule, so nothing uses it by accident. Set to false to leave AWS's permissive default (allow-all within the group) in place."
}

variable "manage_default_network_acl" {
  default     = false
  description = "Whether to take over the VPC's default network ACL. Defaults to false, unlike manage_default_security_group: every subnet without its own tier-level network_acl_rules uses the default one, so stripping its rules with no replacement blocks all traffic for that subnet unless default_network_acl_rules supplies one."
}

variable "default_network_acl_rules" {
  default     = []
  description = "Rules for the default network ACL, applied only if manage_default_network_acl is true. Each entry needs rule_number, egress (bool), protocol, action ('allow' or 'deny'), one of cidr_block or ipv6_cidr_block, and optional from_port/to_port (both default 0, AWS's own convention for an all-ports rule)."
  type = list(object({
    rule_number     = number
    egress          = bool
    protocol        = string
    action          = string
    cidr_block      = optional(string)
    ipv6_cidr_block = optional(string)
    from_port       = optional(number, 0)
    to_port         = optional(number, 0)
  }))

  validation {
    condition = alltrue([
      for r in var.default_network_acl_rules : (r.cidr_block != null) != (r.ipv6_cidr_block != null) && contains(["allow", "deny"], r.action)
    ])
    error_message = "Each default_network_acl_rules entry needs exactly one of cidr_block or ipv6_cidr_block, and action must be 'allow' or 'deny'."
  }
}

variable "tags" {
  default     = null
  description = "A map of tags to assign to all resources created by this module."
}
