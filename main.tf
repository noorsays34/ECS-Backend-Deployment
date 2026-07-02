########################################
# Shared Platform Resources
########################################

data "aws_ecs_cluster" "platform" {
  cluster_name = var.cluster_name
}

data "aws_lb" "platform" {
  name = var.alb_name
}

data "aws_lb_listener" "http" {
  load_balancer_arn = data.aws_lb.platform.arn
  port              = 80
}

########################################
# Shared IAM Role
########################################

data "aws_iam_role" "ecs_execution_role" {
  name = "concproject-ecs-execution-role"
}

########################################
# Shared Networking
########################################

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

}

########################################
# Shared ECS Security Group
########################################

data "aws_security_group" "ecs_sg" {
  name = "concproject-ecs-sg"
}

########################################
# ECR Repository
########################################

resource "aws_ecr_repository" "app" {

  name = var.app_name

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project = "CONC"
    Owner   = var.app_name
  }

}

########################################
# CloudWatch Log Group
########################################

resource "aws_cloudwatch_log_group" "app" {

  name              = "/ecs/${var.app_name}"
  retention_in_days = 7

  tags = {
    Project = "CONC"
    Owner   = var.app_name
  }

}

########################################
# Target Group
########################################

resource "aws_lb_target_group" "app" {

  name = "${var.app_name}-tg"

  port = var.container_port

  protocol = "HTTP"

  target_type = "ip"

  vpc_id = data.aws_vpc.default.id

  health_check {

    enabled = true

    path = "/health"

    protocol = "HTTP"

    port = "traffic-port"

    matcher = "200"

    healthy_threshold = 2

    unhealthy_threshold = 2

    interval = 30

    timeout = 5

  }

  tags = {
    Project = "CONC"
    Owner   = var.app_name
  }

}

########################################
# ECS Task Definition
########################################

resource "aws_ecs_task_definition" "app" {

  family = var.app_name

  requires_compatibilities = ["FARGATE"]

  network_mode = "awsvpc"

  cpu    = var.task_cpu
  memory = var.task_memory

  execution_role_arn = data.aws_iam_role.ecs_execution_role.arn

  container_definitions = jsonencode([
    {

      name  = var.app_name

      image = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"

      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"

        options = {
          awslogs-group         = aws_cloudwatch_log_group.app.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "ecs"
        }
      }

    }
  ])

  tags = {
    Project = "CONC"
    Owner   = var.app_name
  }

}

########################################
# ECS Service
########################################

resource "aws_ecs_service" "app" {

  name = "${var.app_name}-service"

  cluster = data.aws_ecs_cluster.platform.id

  task_definition = aws_ecs_task_definition.app.arn

  desired_count = 1

  launch_type = "FARGATE"

  network_configuration {

    subnets = data.aws_subnets.default.ids

    security_groups = [
      data.aws_security_group.ecs_sg.id
    ]

    assign_public_ip = true

  }

  load_balancer {

    target_group_arn = aws_lb_target_group.app.arn

    container_name = var.app_name

    container_port = var.container_port

  }

  depends_on = [
    aws_lb_target_group.app
  ]

  tags = {
    Project = "CONC"
    Owner   = var.app_name
  }

}

########################################
# ALB Listener Rule
########################################

resource "aws_lb_listener_rule" "app" {

  listener_arn = data.aws_lb_listener.http.arn

  priority = var.listener_priority

  action {

    type = "forward"

    target_group_arn = aws_lb_target_group.app.arn

  }

  condition {

    path_pattern {

      values = [
        var.path_pattern
      ]

    }

  }

  tags = {
    Project = "CONC"
    Owner   = var.app_name
  }

}