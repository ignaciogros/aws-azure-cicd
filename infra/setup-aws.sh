#!/usr/bin/env bash
# Provisiona la infraestructura AWS con AWS CLI (sin Terraform).
# Idempotente: se puede ejecutar varias veces sin duplicar recursos.
set -euo pipefail

# ── Configuración — edita estos valores ───────────────────────────────────────
PROJECT="silence"
REGION="eu-west-1"
GITHUB_ORG="ignaciogros"
GITHUB_REPO="aws-azure-cicd"
# ──────────────────────────────────────────────────────────────────────────────

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")
echo "Cuenta: $ACCOUNT_ID  |  Proyecto: $PROJECT  |  Región: $REGION"
CALLER_ARN=$(aws sts get-caller-identity --query "Arn" --output text --region "$REGION")
if [[ "$CALLER_ARN" == *"voclabs"* ]]; then
  ACADEMY_MODE=true
  echo "Modo AWS Academy detectado — se usarán LabRole y LabInstanceProfile"
else
  ACADEMY_MODE=false
fi
echo ""

# Devuelve vacío si la query de AWS devuelve "None"
_q() { [[ "$1" == "None" ]] && echo "" || echo "$1"; }

# ── VPC ────────────────────────────────────────────────────────────────────────
VPC_ID=$(_q "$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=${PROJECT}-vpc" \
  --query "Vpcs[0].VpcId" --output text --region "$REGION")")
if [[ -z "$VPC_ID" ]]; then
  VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
    --query "Vpc.VpcId" --output text --region "$REGION")
  aws ec2 create-tags --resources "$VPC_ID" \
    --tags "Key=Name,Value=${PROJECT}-vpc" --region "$REGION"
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames --region "$REGION"
fi
echo "VPC: $VPC_ID"

# Internet Gateway
IGW_ID=$(_q "$(aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
  --query "InternetGateways[0].InternetGatewayId" --output text --region "$REGION")")
if [[ -z "$IGW_ID" ]]; then
  IGW_ID=$(aws ec2 create-internet-gateway \
    --query "InternetGateway.InternetGatewayId" --output text --region "$REGION")
  aws ec2 attach-internet-gateway \
    --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION"
fi
echo "IGW: $IGW_ID"

# Subnet
SUBNET_ID=$(_q "$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=cidr-block,Values=10.0.1.0/24" \
  --query "Subnets[0].SubnetId" --output text --region "$REGION")")
if [[ -z "$SUBNET_ID" ]]; then
  SUBNET_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.1.0/24 \
    --query "Subnet.SubnetId" --output text --region "$REGION")
  aws ec2 modify-subnet-attribute \
    --subnet-id "$SUBNET_ID" --map-public-ip-on-launch --region "$REGION"
fi
echo "Subnet: $SUBNET_ID"

# Route table
RT_ID=$(_q "$(aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=${PROJECT}-rt" \
  --query "RouteTables[0].RouteTableId" --output text --region "$REGION")")
if [[ -z "$RT_ID" ]]; then
  RT_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
    --query "RouteTable.RouteTableId" --output text --region "$REGION")
  aws ec2 create-tags --resources "$RT_ID" \
    --tags "Key=Name,Value=${PROJECT}-rt" --region "$REGION"
  aws ec2 create-route --route-table-id "$RT_ID" \
    --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" --region "$REGION" >/dev/null
  aws ec2 associate-route-table \
    --route-table-id "$RT_ID" --subnet-id "$SUBNET_ID" --region "$REGION" >/dev/null
fi
echo "Route table: $RT_ID"

# Security group (puerto 80 entrada, todo salida)
SG_ID=$(_q "$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${PROJECT}-sg" \
  --query "SecurityGroups[0].GroupId" --output text --region "$REGION")")
if [[ -z "$SG_ID" ]]; then
  SG_ID=$(aws ec2 create-security-group \
    --group-name "${PROJECT}-sg" --description "${PROJECT} ECS node" \
    --vpc-id "$VPC_ID" --query "GroupId" --output text --region "$REGION")
  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" --protocol tcp --port 80 --cidr 0.0.0.0/0 --region "$REGION" >/dev/null
fi
echo "Security group: $SG_ID"
echo ""

# ── IAM ────────────────────────────────────────────────────────────────────────
if [[ "$ACADEMY_MODE" == "true" ]]; then
  # Academy bloquea iam:CreateRole — usar recursos preexistentes del lab
  INSTANCE_PROFILE="LabInstanceProfile"
  EXEC_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/LabRole"
  echo "IAM: usando LabRole y LabInstanceProfile (Academy)"
else
  INSTANCE_ROLE="${PROJECT}-ecs-instance-role"
  aws iam get-role --role-name "$INSTANCE_ROLE" >/dev/null 2>&1 || {
    aws iam create-role --role-name "$INSTANCE_ROLE" \
      --assume-role-policy-document \
      '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
    aws iam attach-role-policy --role-name "$INSTANCE_ROLE" \
      --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
    echo "Rol instancia EC2 creado"
  }

  INSTANCE_PROFILE="${PROJECT}-ecs-profile"
  aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE" >/dev/null 2>&1 || {
    aws iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE" >/dev/null
    aws iam add-role-to-instance-profile \
      --instance-profile-name "$INSTANCE_PROFILE" --role-name "$INSTANCE_ROLE"
    echo "Instance profile creado"
  }

  EXEC_ROLE="${PROJECT}-task-exec-role"
  EXEC_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${EXEC_ROLE}"
  aws iam get-role --role-name "$EXEC_ROLE" >/dev/null 2>&1 || {
    aws iam create-role --role-name "$EXEC_ROLE" \
      --assume-role-policy-document \
      '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
    aws iam attach-role-policy --role-name "$EXEC_ROLE" \
      --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
    echo "Rol task execution creado"
  }

  OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
  aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1 || {
    aws iam create-open-id-connect-provider \
      --url "https://token.actions.githubusercontent.com" \
      --client-id-list "sts.amazonaws.com" \
      --thumbprint-list \
        "6938fd4d98bab03faadb97b34396831e3780aea1" \
        "1c58a3a8518e8759bf075b76b750d4f2df264fcd" >/dev/null
    echo "OIDC provider creado"
  }

  GH_ROLE="${PROJECT}-github-actions-role"
  ECR_ARN="arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/${PROJECT}-web"

  TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${OIDC_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:${GITHUB_ORG}/${GITHUB_REPO}:*" }
    }
  }]
}
EOF
)

  aws iam get-role --role-name "$GH_ROLE" >/dev/null 2>&1 || {
    aws iam create-role --role-name "$GH_ROLE" \
      --assume-role-policy-document "$TRUST_POLICY" >/dev/null
    echo "Rol GitHub Actions creado"
  }

  ACTIONS_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["ecr:GetAuthorizationToken"], "Resource": "*" },
    { "Effect": "Allow",
      "Action": ["ecr:BatchCheckLayerAvailability","ecr:GetDownloadUrlForLayer",
                 "ecr:BatchGetImage","ecr:InitiateLayerUpload","ecr:UploadLayerPart",
                 "ecr:CompleteLayerUpload","ecr:PutImage"],
      "Resource": ["${ECR_ARN}"] },
    { "Effect": "Allow",
      "Action": ["ecs:RegisterTaskDefinition","ecs:DescribeTaskDefinition",
                 "ecs:DescribeServices","ecs:UpdateService","ecs:ListTasks"],
      "Resource": "*" },
    { "Effect": "Allow", "Action": "iam:PassRole", "Resource": "${EXEC_ROLE_ARN}" },
    { "Effect": "Allow", "Action": ["ec2:DescribeInstances"], "Resource": "*" }
  ]
}
EOF
)
  aws iam put-role-policy --role-name "$GH_ROLE" \
    --policy-name "${PROJECT}-github-actions-policy" \
    --policy-document "$ACTIONS_POLICY"
fi
echo "IAM listo"
echo ""

# ── ECR ────────────────────────────────────────────────────────────────────────
aws ecr describe-repositories --repository-names "${PROJECT}-web" \
  --region "$REGION" >/dev/null 2>&1 || {
  aws ecr create-repository --repository-name "${PROJECT}-web" \
    --image-tag-mutability MUTABLE --region "$REGION" >/dev/null
  aws ecr put-lifecycle-policy --repository-name "${PROJECT}-web" --region "$REGION" \
    --lifecycle-policy-text \
    '{"rules":[{"rulePriority":1,"description":"Mantener últimas 5 imágenes","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":5},"action":{"type":"expire"}}]}' >/dev/null
  echo "ECR repo creado"
}

# ── ECS cluster ────────────────────────────────────────────────────────────────
CLUSTER_STATUS=$(aws ecs describe-clusters --clusters "${PROJECT}-cluster" \
  --query "clusters[0].status" --output text --region "$REGION" 2>/dev/null || echo "")
[[ "$CLUSTER_STATUS" == "ACTIVE" ]] || {
  aws ecs create-cluster --cluster-name "${PROJECT}-cluster" --region "$REGION" >/dev/null
  echo "ECS cluster creado"
}

# CloudWatch log group
aws logs describe-log-groups \
  --log-group-name-prefix "/ecs/${PROJECT}-web" --region "$REGION" \
  --query "logGroups[0].logGroupName" --output text 2>/dev/null \
  | grep -q "/ecs/${PROJECT}-web" || {
  aws logs create-log-group --log-group-name "/ecs/${PROJECT}-web" --region "$REGION"
  aws logs put-retention-policy \
    --log-group-name "/ecs/${PROJECT}-web" --retention-in-days 7 --region "$REGION"
  echo "Log group creado"
}

# ── EC2 — nodo ECS ─────────────────────────────────────────────────────────────
INSTANCE_ID=$(_q "$(aws ec2 describe-instances \
  --filters \
    "Name=tag:Name,Values=${PROJECT}-ecs-node" \
    "Name=instance-state-name,Values=running,pending,stopped" \
  --query "Reservations[0].Instances[0].InstanceId" --output text --region "$REGION")")
if [[ -z "$INSTANCE_ID" ]]; then
  AMI=$(aws ssm get-parameter \
    --name /aws/service/ecs/optimized-ami/amazon-linux-2/recommended/image_id \
    --query "Parameter.Value" --output text --region "$REGION")

  # IAM necesita ~10 s para propagar el instance profile antes de asociarlo a EC2
  if [[ "$ACADEMY_MODE" == "false" ]]; then
    echo "Esperando propagación de IAM..."
    sleep 12
  fi

  INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI" \
    --instance-type t3.micro \
    --subnet-id "$SUBNET_ID" \
    --security-group-ids "$SG_ID" \
    --iam-instance-profile "Name=${INSTANCE_PROFILE}" \
    --user-data "$(printf '#!/bin/bash\necho ECS_CLUSTER=%s-cluster >> /etc/ecs/ecs.config' "$PROJECT")" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT}-ecs-node}]" \
    --query "Instances[0].InstanceId" --output text --region "$REGION")
  echo "EC2 creada ($INSTANCE_ID), esperando arranque..."
  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
else
  echo "EC2 ya existe: $INSTANCE_ID"
fi

EC2_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text --region "$REGION")
echo "EC2 IP: $EC2_IP"
echo ""

# ── ECS task definition (solo si no existe ninguna revisión) ───────────────────
aws ecs describe-task-definition --task-definition "${PROJECT}-web" \
  --region "$REGION" >/dev/null 2>&1 || {
  TASK_DEF=$(cat <<EOF
{
  "family": "${PROJECT}-web",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "networkMode": "bridge",
  "requiresCompatibilities": ["EC2"],
  "containerDefinitions": [{
    "name": "web",
    "image": "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${PROJECT}-web:latest",
    "essential": true,
    "memory": 256,
    "portMappings": [{"containerPort": 80, "hostPort": 80, "protocol": "tcp"}],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/${PROJECT}-web",
        "awslogs-region": "${REGION}",
        "awslogs-stream-prefix": "ecs"
      }
    }
  }]
}
EOF
  )
  aws ecs register-task-definition --cli-input-json "$TASK_DEF" \
    --region "$REGION" >/dev/null
  echo "Task definition registrada"
}

# ── ECS service ────────────────────────────────────────────────────────────────
SVC_STATUS=$(aws ecs describe-services \
  --cluster "${PROJECT}-cluster" --services "${PROJECT}-web-svc" \
  --query "services[0].status" --output text --region "$REGION" 2>/dev/null || echo "")
[[ "$SVC_STATUS" == "ACTIVE" ]] || {
  TD_ARN=$(aws ecs describe-task-definition --task-definition "${PROJECT}-web" \
    --query "taskDefinition.taskDefinitionArn" --output text --region "$REGION")
  aws ecs create-service \
    --cluster "${PROJECT}-cluster" \
    --service-name "${PROJECT}-web-svc" \
    --task-definition "$TD_ARN" \
    --desired-count 1 \
    --launch-type EC2 \
    --region "$REGION" >/dev/null
  echo "ECS service creado"
}

# ── Outputs ────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════"
echo " Infraestructura lista"
echo "════════════════════════════════════════════════════"
echo ""
echo "  ec2_public_ip  = $EC2_IP"
echo "  aws_account_id = $ACCOUNT_ID"
echo ""
if [[ "$ACADEMY_MODE" == "true" ]]; then
  echo "  GitHub Actions — credenciales estáticas (modo Academy)"
  echo "  Copia los valores del panel 'AWS Details' de tu sesión de laboratorio"
  echo "  y añádelos en GitHub → Settings → Secrets and variables → Actions:"
  echo ""
  echo "    Secrets (New repository secret):"
  echo "      AWS_ACCESS_KEY_ID     → aws_access_key_id"
  echo "      AWS_SECRET_ACCESS_KEY → aws_secret_access_key"
  echo "      AWS_SESSION_TOKEN     → aws_session_token"
  echo ""
  echo "    Variables (New repository variable):"
  echo "      AWS_ACCOUNT_ID        → $ACCOUNT_ID"
  echo ""
  echo "  AVISO: las credenciales expiran con la sesión."
  echo "  Actualiza los tres secrets cada vez que reinicies el laboratorio."
else
  GH_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${GH_ROLE}"
  echo "  github_actions_role_arn = $GH_ROLE_ARN"
  echo ""
  echo "  GitHub → Settings → Variables → New repository variable:"
  echo "    AWS_ACCOUNT_ID  →  $ACCOUNT_ID"
  echo "    AWS_ROLE_ARN    →  $GH_ROLE_ARN"
fi
echo ""
echo "  URL (disponible ~3 min después del primer push a main):"
echo "    http://$EC2_IP"
