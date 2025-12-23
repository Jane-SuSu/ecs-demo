# 教學文：https://judoscale.com/blog/terraform-on-amazon-ecs

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.56"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0.2"
    }
  }
}

# Configure AWS Provider
provider "aws" {
  region = "ap-northeast-1"
}

# 1. 建立 VPC & Subnets
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  version = "~> 3.19.0"

  name = "tf-demo"

  azs = ["ap-northeast-1a", "ap-northeast-1c"]
  cidr = "10.0.0.0/16"

  # Expose public subnetworks to the Internet
  create_igw = true

  # Hide private subnetworks behind NAT Gateway
  enable_nat_gateway = true

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets = ["10.0.101.0/24", "10.0.102.0/24"]
  single_nat_gateway = true
}

# 2. 建 ALB & SecurityGroup & TargetGroup
module "alb" {
 source  = "terraform-aws-modules/alb/aws"
 version = "~> 8.4.0"

 name = "tf-demo"
 load_balancer_type = "application"
 security_groups = [module.vpc.default_security_group_id]
 subnets = module.vpc.public_subnets
 vpc_id = module.vpc.vpc_id

 security_group_rules = {
  # 開放 8080 port 給 hello service
  ingress_8080 = {
   type        = "ingress"
   from_port   = 8080
   to_port     = 8080
   protocol    = "TCP"
   description = "Permit incoming HTTP requests for hello service"
   cidr_blocks = ["0.0.0.0/0"]
  }
  # 開放 8081 port 給 world service
  ingress_8081 = {
   type        = "ingress"
   from_port   = 8081
   to_port     = 8081
   protocol    = "TCP"
   description = "Permit incoming HTTP requests for world service"
   cidr_blocks = ["0.0.0.0/0"]
  }
  egress_all = {
   type        = "egress"
   from_port   = 0
   to_port     = 0
   protocol    = "-1"
   description = "Permit outgoing requests"
   cidr_blocks = ["0.0.0.0/0"]
  }
 }

 # 兩個 listener，分別監聽 8080 和 8081
 http_tcp_listeners = [
  {
   port               = 8080
   protocol           = "HTTP"
   target_group_index = 0  # hello service target group
  },
  {
   port               = 8081
   protocol           = "HTTP"
   target_group_index = 1  # world service target group
  }
 ]

 # 兩個 target group，分別對應 hello 和 world
 target_groups = [
  {
   name             = "hello-tg"
   backend_port     = 5000
   backend_protocol = "HTTP"
   target_type      = "ip"
   host_header      = ["hello-service"]
  },
  {
   name             = "world-tg"
   backend_port     = 5001
   backend_protocol = "HTTP"
   target_type      = "ip"
   host_header      = ["world-service"]
  }
 ]
}

# 3. 建 ECS Cluster

# 建立 Service Discovery Namespace for Service Connect
resource "aws_service_discovery_http_namespace" "tf_demo" {
  name        = "tf-demo"
  description = "Service Connect namespace for tf-demo"
}

module "ecs" {
  source  = "terraform-aws-modules/ecs/aws"
  version = "~> 4.1.3"

  cluster_name = "tf-demo"

  # 預設 Capacity provider strategy 不用每次建 service 都指定
  fargate_capacity_providers = {
    FARGATE = {
      default_capacity_provider_strategy = {
      base   = 20
      weight = 50
      }
    }
    FARGATE_SPOT = {
      default_capacity_provider_strategy = {
      weight = 50
      }
    }
  }
}


# 4. 建 ECR
## 1. 建立 ECR repository
## 2. 用當前目錄的 Dockerfile build image
## 3. Tag 上時間戳記
## 4. 推送到 ECR
## 5. 舊的 image 自動清理（只留 3 個）

data "aws_caller_identity" "this" {}
data "aws_ecr_authorization_token" "this" {}
data "aws_region" "this" {}
locals { ecr_address = format("%v.dkr.ecr.%v.amazonaws.com", data.aws_caller_identity.this.account_id, data.aws_region.this.name) }
provider "docker" {
  registry_auth {
    address  = local.ecr_address
    password = data.aws_ecr_authorization_token.this.password
    username = data.aws_ecr_authorization_token.this.user_name
  }
}

## hello ECR repository
module "ecr_hello" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "~> 1.6.0"

  # 刪除時連 image 一起刪
  repository_force_delete = true

  repository_name = "tf-demo/hello"

  # 自動清理舊 image，只保留最新 3 個
  repository_lifecycle_policy = jsonencode({
    rules = [{
      action = { type = "expire" }
      description = "Delete old images"
      rulePriority = 1
      selection = {
        countNumber = 3
        countType = "imageCountMoreThan"
        tagStatus = "any"
      }
    }]
  })
}

## world ECR repository
module "ecr_world" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "~> 1.6.0"

  # 刪除時連 image 一起刪
  repository_force_delete = true

  repository_name = "tf-demo/world"

  # 自動清理舊 image，只保留最新 3 個
  repository_lifecycle_policy = jsonencode({
    rules = [{
      action = { type = "expire" }
      description = "Delete old images"
      rulePriority = 1
      selection = {
        countNumber = 3
        countType = "imageCountMoreThan"
        tagStatus = "any"
      }
    }]
  })
}

## hello image
resource "docker_image" "helloimage" {
  name = format("%v:%v", module.ecr_hello.repository_url, formatdate("YYYYMMDDhhmmss", timestamp()))
  build {
    context    = "."
    dockerfile = "Dockerfile.hello"
    platform   = "linux/amd64"
  }
}

resource "docker_registry_image" "helloimage" {
  keep_remotely = false
  name = resource.docker_image.helloimage.name
}

## world image
resource "docker_image" "worldimage" {
  name = format("%v:%v", module.ecr_world.repository_url, formatdate("YYYYMMDDhhmmss", timestamp()))
  build {
    context    = "."
    dockerfile = "Dockerfile.world"
    platform   = "linux/amd64"
  }
}

resource "docker_registry_image" "worldimage" {
  keep_remotely = false
  name = resource.docker_image.worldimage.name
}

# 5. 建 Task Definition

# --- 1. Execution Role (基礎設施用：拉 Image, 寫 Log) ---
resource "aws_iam_role" "ecsTaskExecutionRole" {
  name               = "ecsTaskExecutionRole"
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
}

# 確保 log group 存在 (避免 ResourceInitializationError)
resource "aws_cloudwatch_log_group" "ecs_otel_sidecar" {
  name              = "/ecs/ecs-aws-otel-sidecar-collector"
  retention_in_days = 7
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ecsTaskExecutionRole_policy" {
  role       = aws_iam_role.ecsTaskExecutionRole.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# --- 2. Task Role (應用程式用：寫 X-Ray, 存取 S3 等) ---
resource "aws_iam_role" "ecsTaskRole" {
  name = "ecsTaskRole"
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
}

# 賦予 X-Ray 寫入權限
resource "aws_iam_role_policy_attachment" "ecsTaskRole_xray" {
  role       = aws_iam_role.ecsTaskRole.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXrayWriteOnlyAccess"
}


## hello task
resource "aws_ecs_task_definition" "hello" {
  container_definitions = jsonencode([
    {
      essential = true,
      image = resource.docker_registry_image.helloimage.name,
      name = "hello-container",
      portMappings = [{
        containerPort = 5000,
        hostPort = 5000,
        name = "hello-tcp",
        protocol = "tcp",
        appProtocol = "http"
      }],
      # 讓 App 知道 OTEL 要送去哪
      environment = [
        { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://localhost:4317" },
        { name = "WORLD_SERVICE_URL", value = "http://world-service:5001" }
      ]
    },
    {
      # --- ADOT Sidecar ---
      name      = "aws-otel-collector"
      image     = "public.ecr.aws/aws-observability/aws-otel-collector:latest"
      essential = true
      # 使用 AWS 預設的 config，它會把 OTLP 轉成 X-Ray 格式
      command   = ["--config=/etc/ecs/ecs-default-config.yaml"]
      portMappings = []
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs_otel_sidecar.name
          "awslogs-region"        = "ap-northeast-1"
          "awslogs-stream-prefix" = "ecs"
          # 移除 awslogs-create-group，因為我們已經用 Terraform 建好了，避免權限不足
        }
      }
    }
  ])

  cpu = 256
  execution_role_arn = aws_iam_role.ecsTaskExecutionRole.arn
  task_role_arn      = aws_iam_role.ecsTaskRole.arn

  family = "tf-demo-example-tasks-hello"
  memory = 512
  network_mode = "awsvpc"
  requires_compatibilities = ["FARGATE"]

  # Only set the below if building on an ARM64 computer like an Apple Silicon Mac
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
}

## world task
resource "aws_ecs_task_definition" "world" {
  container_definitions = jsonencode([
    {
      essential = true,
      image = resource.docker_registry_image.worldimage.name,
      name = "world-container",
      portMappings = [{
        containerPort = 5001,
        hostPort = 5001,
        name = "world-tcp",
        protocol = "tcp",
        appProtocol = "http"
      }],
      environment = [
        { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://localhost:4317" },
        { name = "HELLO_SERVICE_URL", value = "http://hello-service:5000" }
      ]
    },
    {
      # --- ADOT Sidecar ---
      name      = "aws-otel-collector"
      image     = "public.ecr.aws/aws-observability/aws-otel-collector:latest"
      essential = true
      command   = ["--config=/etc/ecs/ecs-default-config.yaml"]
      portMappings = []
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs_otel_sidecar.name
          "awslogs-region"        = "ap-northeast-1"
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  cpu = 256
  execution_role_arn = aws_iam_role.ecsTaskExecutionRole.arn
  task_role_arn      = aws_iam_role.ecsTaskRole.arn

  family = "tf-demo-example-tasks-world"
  memory = 512
  network_mode = "awsvpc"
  requires_compatibilities = ["FARGATE"]

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
}


# 6. 建 Service
resource "aws_ecs_service" "hello" {
  cluster = module.ecs.cluster_id
  desired_count = 1
  launch_type = "FARGATE"
  name = "hello-service"
  task_definition = resource.aws_ecs_task_definition.hello.arn

  lifecycle {
    ignore_changes = [desired_count]
  }

  load_balancer {
    container_name = "hello-container"
    container_port = 5000
    target_group_arn = module.alb.target_group_arns[0]
  }

  network_configuration {
    security_groups = [module.vpc.default_security_group_id]
    subnets = module.vpc.private_subnets
  }

  # 啟用 Service Connect
  service_connect_configuration {
    enabled = true
    namespace = aws_service_discovery_http_namespace.tf_demo.arn

    service {
      port_name = "hello-tcp"
      discovery_name = "hello-service"
      client_alias {
        port = 5000
        dns_name = "hello-service"
      }
    }
  }
}

resource "aws_ecs_service" "world" {
  cluster = module.ecs.cluster_id
  desired_count = 1
  launch_type = "FARGATE"
  name = "world-service"
  task_definition = resource.aws_ecs_task_definition.world.arn

  lifecycle {
    ignore_changes = [desired_count]
  }

  load_balancer {
    container_name = "world-container"
    container_port = 5001
    target_group_arn = module.alb.target_group_arns[1]
  }

  network_configuration {
    security_groups = [module.vpc.default_security_group_id]
    subnets = module.vpc.private_subnets
  }

  # 啟用 Service Connect
  service_connect_configuration {
    enabled = true
    namespace = aws_service_discovery_http_namespace.tf_demo.arn

    service {
      port_name = "world-tcp"
      discovery_name = "world-service"
      client_alias {
        port = 5001
        dns_name = "world-service"
      }
    }
  }
}

output "hello-service-url" { value = "http://${module.alb.lb_dns_name}:8080" }
output "world-service-url" { value = "http://${module.alb.lb_dns_name}:8081" }


# Autoscaling ECS with Queue Time 後面還沒做
