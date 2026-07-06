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

      environment = [
        {
          name  = "CLIENT_URL"
          value = "https://${aws_cloudfront_distribution.frontend.domain_name}"
        },
        {
          name  = "NODE_ENV"
          value = "production"
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

########################################
# Frontend S3 Bucket
########################################

resource "aws_s3_bucket" "frontend" {

  bucket = var.frontend_bucket_name

  tags = {
    Project = "CONC"
    Owner   = var.app_name
  }

}

resource "aws_s3_bucket_public_access_block" "frontend" {

  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

}

########################################
# CloudFront Origin Access Control
########################################

resource "aws_cloudfront_origin_access_control" "frontend" {

  name                              = "${var.frontend_bucket_name}-oac"
  description                       = "OAC for ${var.frontend_bucket_name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"

}

########################################
# S3 Bucket Policy (Allow CloudFront OAC)
########################################

resource "aws_s3_bucket_policy" "frontend" {

  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.frontend.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.frontend.arn
          }
        }
      }
    ]
  })

}

########################################
# CloudFront Distribution
########################################

resource "aws_cloudfront_distribution" "frontend" {

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  price_class         = var.cloudfront_price_class

  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  ########################################
  # Origin 1: S3 (static files)
  ########################################

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  ########################################
  # Origin 2: ALB (API proxy)
  ########################################

  origin {
    domain_name = data.aws_lb.platform.dns_name
    origin_id   = "alb-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    origin_path = var.path_pattern
  }

  ########################################
  # Default behavior: S3 (static files)
  ########################################

  default_cache_behavior {
    target_origin_id       = "s3-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  ########################################
  # Behavior: /api/v1/* → ALB (API proxy)
  ########################################

  ordered_cache_behavior {
    path_pattern           = "/api/v1/*"
    target_origin_id       = "alb-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    forwarded_values {
      query_string = true
      headers      = ["Origin", "Authorization", "Content-Type"]
      cookies {
        forward = "all"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Project = "CONC"
    Owner   = var.app_name
  }

}