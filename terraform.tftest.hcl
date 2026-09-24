mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }

  mock_resource "aws_vpc" {
    defaults = {
      ipv6_cidr_block = "2600:1f18:1234:5600::/56"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

run "secondary_cidr_blocks_needs_one_source" {
  command = plan

  variables {
    secondary_cidr_blocks = {
      extra = {}
    }
  }

  expect_failures = [var.secondary_cidr_blocks]
}

run "availability_zones_empty_list_rejected" {
  command = plan

  variables {
    availability_zones = []
  }

  expect_failures = [var.availability_zones]
}

run "custom_routes_needs_one_destination_and_target" {
  command = plan

  variables {
    subnets = {
      isolated = {
        custom_routes = [{
          cidr_block      = "10.0.0.0/16"
          ipv6_cidr_block = "::/0"
          gateway_id      = "igw-12345678"
        }]
      }
    }
  }

  expect_failures = [var.subnets]
}

run "network_acl_rules_needs_valid_action" {
  command = plan

  variables {
    subnets = {
      web = {
        public = true
        network_acl_rules = [{
          rule_number = 100
          egress      = false
          protocol    = "-1"
          action      = "reject"
          cidr_block  = "10.0.0.0/16"
        }]
      }
    }
  }

  expect_failures = [var.subnets]
}

run "private_dns_hostname_type_invalid" {
  command = plan

  variables {
    subnets = {
      web = {
        public                              = true
        private_dns_hostname_type_on_launch = "invalid-type"
      }
    }
  }

  expect_failures = [var.subnets]
}

run "nat_gateway_connectivity_type_invalid" {
  command = plan

  variables {
    nat_gateway_connectivity_type = "hybrid"
  }

  expect_failures = [var.nat_gateway_connectivity_type]
}

run "flow_logs_destination_type_invalid" {
  command = plan

  variables {
    flow_logs = [{
      destination_arn  = "arn:aws:logs:us-east-1:123456789012:log-group:example"
      destination_type = "kinesis"
    }]
  }

  expect_failures = [var.flow_logs]
}

run "flow_logs_traffic_type_invalid" {
  command = plan

  variables {
    flow_logs = [{
      destination_arn = "arn:aws:logs:us-east-1:123456789012:log-group:example"
      traffic_type    = "SOME"
    }]
  }

  expect_failures = [var.flow_logs]
}

run "flow_logs_max_aggregation_interval_invalid" {
  command = plan

  variables {
    flow_logs = [{
      destination_arn          = "arn:aws:logs:us-east-1:123456789012:log-group:example"
      max_aggregation_interval = 300
    }]
  }

  expect_failures = [var.flow_logs]
}

run "default_network_acl_rules_invalid_action" {
  command = plan

  variables {
    manage_default_network_acl = true
    default_network_acl_rules = [{
      rule_number = 100
      egress      = false
      protocol    = "-1"
      action      = "reject"
      cidr_block  = "10.0.0.0/16"
    }]
  }

  expect_failures = [var.default_network_acl_rules]
}

run "secondary_ipv6_cidr_blocks_needs_one_source" {
  command = plan

  variables {
    secondary_ipv6_cidr_blocks = {
      extra = {}
    }
  }

  expect_failures = [var.secondary_ipv6_cidr_blocks]
}

run "instance_tenancy_invalid" {
  command = plan

  variables {
    instance_tenancy = "host"
  }

  expect_failures = [var.instance_tenancy]
}

run "nat_gateway_tier_nonexistent_rejected" {
  command = plan

  variables {
    nat_gateway_tier = "does-not-exist"
  }

  expect_failures = [var.nat_gateway_tier]
}

run "nat_gateway_tier_not_public_rejected" {
  command = plan

  variables {
    subnets = {
      public  = { public = true }
      private = { nat_gateway_access = true }
    }
    nat_gateway_tier = "private"
  }

  expect_failures = [var.nat_gateway_tier]
}

run "nat_gateway_tier_required_for_private_nat" {
  command = plan

  variables {
    nat_gateway_connectivity_type = "private"
  }

  expect_failures = [var.nat_gateway_tier]
}

run "interface_endpoint_subnet_tiers_invalid_tier_rejected" {
  command = plan

  variables {
    interface_endpoints = {
      ssm = { service_name = "com.amazonaws.us-east-1.ssm" }
    }
    interface_endpoint_subnet_tiers = ["does-not-exist"]
  }

  expect_failures = [var.interface_endpoint_subnet_tiers]
}

run "cidr_source_nonexistent_rejected" {
  command = plan

  variables {
    subnets = {
      isolated = { cidr_source = "does-not-exist" }
    }
  }

  expect_failures = [var.subnets]
}

run "default_config_creates_expected_resources" {
  command = plan

  assert {
    condition     = length(aws_subnet.resource) == 4
    error_message = "Default config (2 tiers x 2 AZs) should create 4 subnets."
  }

  assert {
    condition     = length(aws_internet_gateway.resource) == 1
    error_message = "The public tier should create one internet gateway."
  }

  assert {
    condition     = length(aws_nat_gateway.resource) == 2
    error_message = "Default NAT gateway count should be one per availability zone."
  }

  assert {
    condition     = length(aws_eip.nat) == 2
    error_message = "Public NAT gateways should each get a new Elastic IP by default."
  }

  assert {
    condition     = length(aws_route_table.resource) == 4
    error_message = "Every subnet (both tiers) should get its own route table by default."
  }

  assert {
    condition     = length(aws_network_acl.resource) == 0
    error_message = "No tier sets network_acl_rules by default, so no dedicated NACLs should exist."
  }

  assert {
    condition     = length(aws_egress_only_internet_gateway.resource) == 0
    error_message = "IPv6 is disabled by default, so no egress-only internet gateway should exist."
  }
}

run "isolated_tier_has_no_route_table" {
  command = plan

  variables {
    subnets = {
      isolated = {}
    }
  }

  assert {
    condition     = length(aws_subnet.resource) == 2
    error_message = "One tier x 2 AZs should create 2 subnets."
  }

  assert {
    condition     = length(aws_route_table.resource) == 0
    error_message = "A tier with no public, nat_gateway_access, custom_routes, or propagating_vgws should stay on the VPC's default route table."
  }

  assert {
    condition     = length(aws_internet_gateway.resource) == 0
    error_message = "No public tier means no internet gateway should be created."
  }

  assert {
    condition     = length(aws_nat_gateway.resource) == 0
    error_message = "No tier requests NAT access, so no NAT gateway should be created."
  }
}

run "custom_routes_gives_isolated_tier_a_route_table" {
  command = plan

  variables {
    subnets = {
      isolated = {
        custom_routes = [{
          cidr_block         = "10.100.0.0/16"
          transit_gateway_id = "tgw-12345678"
        }]
      }
    }
  }

  assert {
    condition     = length(aws_route_table.resource) == 2
    error_message = "custom_routes alone should give an otherwise-isolated tier its own route table per AZ."
  }
}

run "nat_disabled_keeps_route_table_shell" {
  command = plan

  variables {
    nat_gateway_count = 0
  }

  assert {
    condition     = length(aws_nat_gateway.resource) == 0
    error_message = "nat_gateway_count = 0 should create no NAT gateways."
  }

  assert {
    condition     = length(aws_eip.nat) == 0
    error_message = "nat_gateway_count = 0 should create no Elastic IPs."
  }

  assert {
    condition     = length(aws_route_table.resource) == 4
    error_message = "A nat_gateway_access tier should still get its own route table even with NAT disabled — only the NAT route itself is omitted."
  }
}

run "private_nat_gateway_has_no_eip" {
  command = plan

  variables {
    nat_gateway_connectivity_type = "private"
    nat_gateway_tier              = "private"
  }

  assert {
    condition     = length(aws_eip.nat) == 0
    error_message = "Private NAT gateways should not allocate an Elastic IP."
  }

  assert {
    condition     = length(aws_nat_gateway.resource) == 2
    error_message = "Private NAT gateways should still be created, one per availability zone."
  }

  assert {
    condition     = aws_nat_gateway.resource[0].connectivity_type == "private"
    error_message = "NAT gateway connectivity_type should be 'private'."
  }
}

run "private_nat_with_no_public_tier_anywhere" {
  command = plan

  variables {
    subnets = {
      private = { nat_gateway_access = true }
    }
    nat_gateway_connectivity_type = "private"
    nat_gateway_tier              = "private"
  }

  assert {
    condition     = length(aws_nat_gateway.resource) == 2
    error_message = "A private-NAT-only VPC with no public tier at all should still be able to create NAT gateways when nat_gateway_tier is set explicitly."
  }

  assert {
    condition     = length(aws_internet_gateway.resource) == 0
    error_message = "No tier is public, so no internet gateway should be created."
  }
}

run "nat_eip_allocation_ids_used_instead_of_new_eips" {
  command = plan

  variables {
    nat_eip_allocation_ids = ["eipalloc-aaaaaaaa", "eipalloc-bbbbbbbb"]
  }

  assert {
    condition     = length(aws_eip.nat) == 0
    error_message = "Supplying nat_eip_allocation_ids should skip allocating new Elastic IPs."
  }

  assert {
    condition     = aws_nat_gateway.resource[0].allocation_id == "eipalloc-aaaaaaaa"
    error_message = "The first NAT gateway should use the first supplied allocation ID."
  }

  assert {
    condition     = aws_nat_gateway.resource[1].allocation_id == "eipalloc-bbbbbbbb"
    error_message = "The second NAT gateway should use the second supplied allocation ID."
  }
}

run "ipv6_egress_access_decoupled_from_nat_gateway_access" {
  command = plan

  variables {
    enable_ipv6 = true
    subnets = {
      public = {
        public = true
      }
      private = {
        nat_gateway_access = true
        ipv6_egress_access = false
      }
      ipv6only = {
        ipv6_egress_access = true
      }
    }
  }

  assert {
    condition     = length(aws_egress_only_internet_gateway.resource) == 1
    error_message = "A tier with ipv6_egress_access = true (even with nat_gateway_access unset) should trigger the egress-only internet gateway."
  }

  assert {
    condition     = length(aws_route_table.resource["private-0"].route) == 1
    error_message = "The private tier opted out of IPv6 egress, so its route table should only carry the IPv4 NAT route."
  }

  assert {
    condition     = length(aws_route_table.resource["ipv6only-0"].route) == 1
    error_message = "The ipv6only tier has no public/nat_gateway_access, so its route table should only carry the IPv6 egress-only route."
  }
}

run "per_tier_tags_and_dedicated_network_acl" {
  command = plan

  variables {
    subnets = {
      web = {
        public = true
        tags   = { Team = "platform" }
        network_acl_rules = [{
          rule_number = 100
          egress      = false
          protocol    = "-1"
          action      = "allow"
          cidr_block  = "10.0.0.0/16"
        }]
      }
    }
  }

  assert {
    condition     = aws_subnet.resource["web-0"].tags["Team"] == "platform"
    error_message = "Per-tier tags should be merged onto that tier's subnets."
  }

  assert {
    condition     = length(aws_network_acl.resource) == 1
    error_message = "A tier with network_acl_rules should get its own dedicated network ACL."
  }

  assert {
    condition     = aws_network_acl.resource["web"].tags["Team"] == "platform"
    error_message = "Per-tier tags should also be merged onto that tier's dedicated network ACL."
  }
}

run "multiple_interface_endpoint_subnet_tiers" {
  command = apply

  variables {
    subnets = {
      a = {}
      b = {}
    }
    interface_endpoints = {
      ssm = { service_name = "com.amazonaws.us-east-1.ssm" }
    }
    interface_endpoint_subnet_tiers = ["a", "b"]
  }

  assert {
    condition     = length(aws_vpc_endpoint.interface["ssm"].subnet_ids) == 2
    error_message = "AWS allows only one subnet per AZ per interface endpoint — with 2 AZs, exactly 2 subnet IDs should be used regardless of how many tiers are listed."
  }

  assert {
    condition = toset(aws_vpc_endpoint.interface["ssm"].subnet_ids) == toset([
      aws_subnet.resource["a-0"].id,
      aws_subnet.resource["a-1"].id,
    ])
    error_message = "The first listed tier ('a') should win for every AZ, since every tier covers every AZ."
  }
}

run "instance_tenancy_and_secondary_ipv6_cidr" {
  command = plan

  variables {
    instance_tenancy = "dedicated"
    secondary_ipv6_cidr_blocks = {
      extra = { ipv6_cidr_block = "2001:db8::/56" }
    }
  }

  assert {
    condition     = aws_vpc.resource.instance_tenancy == "dedicated"
    error_message = "instance_tenancy should pass through to the VPC resource."
  }

  assert {
    condition     = length(aws_vpc_ipv6_cidr_block_association.resource) == 1
    error_message = "secondary_ipv6_cidr_blocks should create one association per entry."
  }

  assert {
    condition     = aws_vpc_ipv6_cidr_block_association.resource["extra"].ipv6_cidr_block == "2001:db8::/56"
    error_message = "The secondary IPv6 CIDR block association should use the supplied CIDR."
  }
}

run "gateway_endpoints_and_secondary_ipv4_cidr" {
  command = plan

  variables {
    gateway_endpoints = {
      s3 = {}
    }
    secondary_cidr_blocks = {
      extra = { cidr_block = "10.99.0.0/16" }
    }
  }

  assert {
    condition     = length(aws_vpc_endpoint.gateway) == 1
    error_message = "gateway_endpoints should create one VPC endpoint per entry."
  }

  assert {
    condition     = aws_vpc_endpoint.gateway["s3"].service_name == "com.amazonaws.us-east-1.s3"
    error_message = "Gateway endpoint service_name should be synthesized from the region and service key."
  }

  assert {
    condition     = length(aws_vpc_ipv4_cidr_block_association.resource) == 1
    error_message = "secondary_cidr_blocks should create one association per entry."
  }
}

run "default_security_group_and_network_acl_management" {
  command = plan

  variables {
    manage_default_network_acl = true
    default_network_acl_rules = [{
      rule_number = 100
      egress      = false
      protocol    = "-1"
      action      = "allow"
      cidr_block  = "10.0.0.0/16"
    }]
  }

  assert {
    condition     = length(aws_default_security_group.resource) == 1
    error_message = "manage_default_security_group defaults to true, so the default SG should be managed."
  }

  assert {
    condition     = length(aws_default_network_acl.resource) == 1
    error_message = "manage_default_network_acl = true should manage the default NACL."
  }
}

run "readme_default_minimal" {
  command = plan
}

run "readme_three_tier_isolated_database" {
  command = plan

  variables {
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
}

run "readme_fully_isolated_no_internet_egress" {
  command = plan

  variables {
    subnets = {
      app = {
        newbits = 4
        custom_routes = [{
          cidr_block         = "10.100.0.0/16"
          transit_gateway_id = "tgw-0123456789abcdef0"
        }]
      }
      data = {
        newbits = 8
      }
    }
  }

  assert {
    condition     = length(aws_internet_gateway.resource) == 0
    error_message = "No tier is public, so no internet gateway should be created."
  }

  assert {
    condition     = length(aws_nat_gateway.resource) == 0
    error_message = "No tier requests NAT access, so no NAT gateway should be created."
  }
}

run "readme_cost_optimized_endpoints_no_nat" {
  command = plan

  variables {
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

  assert {
    condition     = length(aws_nat_gateway.resource) == 0
    error_message = "nat_gateway_count = 0 should create no NAT gateways."
  }

  assert {
    condition     = length(aws_vpc_endpoint.gateway) == 2
    error_message = "Both gateway endpoints should be created."
  }
}

run "readme_eks_ready_subnet_tagging" {
  command = plan

  variables {
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

  assert {
    condition     = aws_subnet.resource["public-0"].tags["kubernetes.io/role/elb"] == "1"
    error_message = "EKS discovery tags should be merged onto the public tier's subnets."
  }
}

run "readme_ipv6_dual_stack_nat_free_egress" {
  command = plan

  variables {
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

  assert {
    condition     = length(aws_egress_only_internet_gateway.resource) == 1
    error_message = "A tier with ipv6_egress_access should trigger the egress-only internet gateway."
  }
}

run "readme_flow_logs_to_cloudwatch" {
  command = plan

  variables {
    flow_logs = [{
      destination_arn = "arn:aws:logs:us-east-1:123456789012:log-group:vpc-flow-logs"
    }]
  }

  assert {
    condition     = length(aws_flow_log.resource) == 1
    error_message = "flow_logs should create one aws_flow_log entry."
  }

  assert {
    condition     = length(aws_iam_role.flow_log) == 1
    error_message = "A cloud-watch-logs destination should create the flow log IAM role."
  }
}

run "readme_private_nat_gateway_hybrid" {
  command = plan

  variables {
    subnets = {
      private = {
        newbits            = 4
        nat_gateway_access = true
      }
    }

    nat_gateway_connectivity_type = "private"
    nat_gateway_tier              = "private"
  }

  assert {
    condition     = aws_nat_gateway.resource[0].connectivity_type == "private"
    error_message = "NAT gateway connectivity_type should be 'private'."
  }
}

run "readme_secondary_cidr_carving" {
  command = plan

  variables {
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

  assert {
    condition     = length(aws_vpc_ipv4_cidr_block_association.resource) == 1
    error_message = "secondary_cidr_blocks should create one association."
  }
}
