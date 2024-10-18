# Provider configuration
provider "aws" {
  region = "ap-south-1"
}

# VPC and Networking
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-south-1a"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "ap-south-1b"
  map_public_ip_on_launch = true
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# Security Group allowing HTTP and RTMP
resource "aws_security_group" "allow_http_rtmp" {
  name        = "allow_http_rtmp"
  description = "Allow HTTP and RTMP inbound traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "RTMP from anywhere"
    from_port   = 1935
    to_port     = 1935
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "dhristi-ingress-cluster"
}

# ECS Task Definition
resource "aws_ecs_task_definition" "app" {
  family                   = "dhristi-ingress-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"

  container_definitions = jsonencode([
    {
      name = "dhristi-ingress-container"
      image = "tiangolo/nginx-rtmp:latest"
      portMappings = [
        {
          containerPort = 80
          hostPort = 80
        },
        {
          containerPort = 1935
          hostPort = 1935
        }
      ]
    }
  ])
}

# Application Load Balancer (ALB) for HTTP traffic
resource "aws_lb" "main" {
  name               = "dhristi-ingress-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.allow_http_rtmp.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]
}

# ALB Listener for HTTP
resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ALB Target Group for HTTP traffic
resource "aws_lb_target_group" "app" {
  name       = "dhristi-ingress-tg"
  port       = 80
  protocol   = "HTTP"
  vpc_id     = aws_vpc.main.id
  target_type = "ip"

  health_check {
    healthy_threshold   = "3"
    interval            = "30"
    protocol            = "HTTP"
    matcher             = "200"
    timeout             = "3"
    path                = "/"
    unhealthy_threshold = "2"
  }
}

# Network Load Balancer (NLB) for RTMP traffic
resource "aws_lb" "rtmp_nlb" {
  name               = "dhristi-rtmp-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]
  enable_deletion_protection = false
}

# NLB Listener for RTMP (TCP Port 1935)
resource "aws_lb_listener" "rtmp_listener" {
  load_balancer_arn = aws_lb.rtmp_nlb.arn
  port              = 1935
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.rtmp.arn
  }
}

# NLB Target Group for RTMP traffic
resource "aws_lb_target_group" "rtmp" {
  name       = "dhristi-rtmp-tg"
  port       = 1935
  protocol   = "TCP"
  vpc_id     = aws_vpc.main.id
  target_type = "ip"

  health_check {
    protocol            = "TCP"
    healthy_threshold   = 3
    unhealthy_threshold = 2
    timeout             = 10
    interval            = 30
  }
}

# ECS Service with both ALB and NLB
resource "aws_ecs_service" "main" {
  name            = "dhristi-ingress-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = [aws_subnet.public_a.id, aws_subnet.public_b.id]
    security_groups = [aws_security_group.allow_http_rtmp.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "dhristi-ingress-container"
    container_port   = 80
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.rtmp.arn
    container_name   = "dhristi-ingress-container"
    container_port   = 1935
  }
}

# Output the ALB DNS name for HTTP
output "alb_dns_name" {
  value       = aws_lb.main.dns_name
  description = "The DNS name of the HTTP load balancer"
}

# Output the NLB DNS name for RTMP
output "nlb_dns_name" {
  value       = aws_lb.rtmp_nlb.dns_name
  description = "The DNS name of the RTMP load balancer"
}
