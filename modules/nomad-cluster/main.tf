# ----------------------------------------------------------------------------------------------------------------------
# REQUIRE A SPECIFIC TERRAFORM VERSION OR HIGHER
# ----------------------------------------------------------------------------------------------------------------------
terraform {
  required_version = ">= 0.12.26"
}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE AN AUTO SCALING GROUP (ASG) TO RUN NOMAD USING LAUNCH TEMPLATE
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_autoscaling_group" "autoscaling_group" {
  launch_template {
    id      = aws_launch_template.launch_template.id
    version = "$Latest"
  }

  name                = var.asg_name
  availability_zones  = var.availability_zones
  vpc_zone_identifier = var.subnet_ids

  min_size             = var.min_size
  max_size             = var.max_size
  desired_capacity     = var.desired_capacity
  termination_policies = [var.termination_policies]

  health_check_type         = var.health_check_type
  health_check_grace_period = var.health_check_grace_period
  wait_for_capacity_timeout = var.wait_for_capacity_timeout

  protect_from_scale_in = var.protect_from_scale_in

  enabled_metrics = [
    "GroupAndWarmPoolDesiredCapacity",
    "GroupAndWarmPoolTotalCapacity",
    "GroupDesiredCapacity",
    "GroupInServiceCapacity",
    "GroupInServiceInstances",
    "GroupMaxSize",
    "GroupMinSize",
    "GroupPendingCapacity",
    "GroupPendingInstances",
    "GroupStandbyCapacity",
    "GroupStandbyInstances",
    "GroupTerminatingCapacity",
    "GroupTerminatingInstances",
    "GroupTotalCapacity",
    "GroupTotalInstances",
    "WarmPoolDesiredCapacity",
    "WarmPoolMinSize",
    "WarmPoolPendingCapacity",
    "WarmPoolTerminatingCapacity",
    "WarmPoolTotalCapacity",
    "WarmPoolWarmedCapacity"
  ]

  dynamic "tag" {
    for_each = var.tags

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    ignore_changes = [load_balancers, target_group_arns]
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE LAUNCH TEMPLATE TO DEFINE WHAT RUNS ON EACH INSTANCE IN THE ASG
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_launch_template" "launch_template" {
  name_prefix   = "${var.cluster_name}-"
  image_id      = var.ami_id
  instance_type = var.instance_type
  user_data     = base64encode(var.user_data)

  iam_instance_profile {
    name = aws_iam_instance_profile.instance_profile.name
  }

  key_name = var.ssh_key_name

  vpc_security_group_ids = [
    aws_security_group.lc_security_group.id
  ]

  network_interfaces {
    associate_public_ip_address = var.associate_public_ip_address
    security_groups = [
      aws_security_group.lc_security_group.id
    ]
  }

  ebs_optimized = var.root_volume_ebs_optimized

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = var.root_volume_size
      volume_type           = var.root_volume_type
      delete_on_termination = var.root_volume_delete_on_termination
      encrypted             = true # Set this based on your requirement
    }
  }

  dynamic "block_device_mappings" {
    for_each = var.ebs_block_devices

    content {
      device_name = block_device_mappings.value["device_name"]
      ebs {
        volume_size           = block_device_mappings.value["volume_size"]
        snapshot_id           = lookup(block_device_mappings.value, "snapshot_id", null)
        iops                  = lookup(block_device_mappings.value, "iops", null)
        encrypted             = lookup(block_device_mappings.value, "encrypted", null)
        delete_on_termination = lookup(block_device_mappings.value, "delete_on_termination", null)
      }
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE A SECURITY GROUP TO CONTROL WHAT REQUESTS CAN GO IN AND OUT OF EACH EC2 INSTANCE
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_security_group" "lc_security_group" {
  name_prefix = "${var.cluster_name}-"
  description = "Security group for the ${var.cluster_name} launch template"
  vpc_id      = var.vpc_id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "allow_ssh_inbound" {
  count             = length(var.allowed_ssh_cidr_blocks) > 0 ? 1 : 0
  type              = "ingress"
  from_port         = var.ssh_port
  to_port           = var.ssh_port
  protocol          = "tcp"
  cidr_blocks       = var.allowed_ssh_cidr_blocks
  security_group_id = aws_security_group.lc_security_group.id
}

resource "aws_security_group_rule" "allow_all_outbound" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = var.allow_outbound_cidr_blocks
  security_group_id = aws_security_group.lc_security_group.id
}

# ---------------------------------------------------------------------------------------------------------------------
# THE INBOUND/OUTBOUND RULES FOR THE SECURITY GROUP COME FROM THE NOMAD-SECURITY-GROUP-RULES MODULE
# ---------------------------------------------------------------------------------------------------------------------

module "security_group_rules" {
  source = "../nomad-security-group-rules"

  security_group_id           = aws_security_group.lc_security_group.id
  allowed_inbound_cidr_blocks = var.allowed_inbound_cidr_blocks

  http_port = var.http_port
  rpc_port  = var.rpc_port
  serf_port = var.serf_port
}

# ---------------------------------------------------------------------------------------------------------------------
# ATTACH AN IAM ROLE TO EACH EC2 INSTANCE
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_iam_instance_profile" "instance_profile" {
  name_prefix = "${var.cluster_name}-"
  path        = var.instance_profile_path
  role        = aws_iam_role.instance_role.name

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role" "instance_role" {
  name_prefix        = "${var.cluster_name}-"
  assume_role_policy = data.aws_iam_policy_document.instance_role.json

  permissions_boundary = var.iam_permissions_boundary

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_iam_policy_document" "instance_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}
