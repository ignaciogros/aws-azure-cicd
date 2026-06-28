#!/usr/bin/env bash
# Elimina todos los recursos AWS creados por setup-aws.sh.
set -euo pipefail

PROJECT="silence"
REGION="us-east-1"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")
echo "Eliminando recursos del proyecto '${PROJECT}' en ${REGION}..."
echo ""

_q() { [[ "$1" == "None" ]] && echo "" || echo "$1"; }

# ── ECS service y tareas ───────────────────────────────────────────────────────
echo "ECS service..."
aws ecs update-service --cluster "${PROJECT}-cluster" \
  --service "${PROJECT}-web-svc" --desired-count 0 \
  --region "$REGION" >/dev/null 2>&1 || true
aws ecs delete-service --cluster "${PROJECT}-cluster" \
  --service "${PROJECT}-web-svc" --force \
  --region "$REGION" >/dev/null 2>&1 || true

# Task definitions
echo "Task definitions..."
TASK_ARNS=$(aws ecs list-task-definitions \
  --family-prefix "${PROJECT}-web" \
  --query "taskDefinitionArns[]" --output text --region "$REGION" 2>/dev/null || echo "")
for ARN in $TASK_ARNS; do
  aws ecs deregister-task-definition --task-definition "$ARN" \
    --region "$REGION" >/dev/null || true
done

# ── EC2 ────────────────────────────────────────────────────────────────────────
echo "EC2..."
INSTANCE_ID=$(_q "$(aws ec2 describe-instances \
  --filters \
    "Name=tag:Name,Values=${PROJECT}-ecs-node" \
    "Name=instance-state-name,Values=running,pending,stopped" \
  --query "Reservations[0].Instances[0].InstanceId" --output text --region "$REGION")")
if [[ -n "$INSTANCE_ID" ]]; then
  aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" >/dev/null
  echo "  Esperando terminación de $INSTANCE_ID..."
  aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$REGION"
fi

# ── ECS cluster ────────────────────────────────────────────────────────────────
echo "ECS cluster..."
aws ecs delete-cluster --cluster "${PROJECT}-cluster" \
  --region "$REGION" >/dev/null 2>&1 || true

# ── ECR ────────────────────────────────────────────────────────────────────────
echo "ECR (eliminando imágenes)..."
aws ecr delete-repository --repository-name "${PROJECT}-web" \
  --force --region "$REGION" >/dev/null 2>&1 || true

# ── CloudWatch ─────────────────────────────────────────────────────────────────
echo "Log group..."
aws logs delete-log-group --log-group-name "/ecs/${PROJECT}-web" \
  --region "$REGION" >/dev/null 2>&1 || true

# ── IAM ────────────────────────────────────────────────────────────────────────
echo "IAM roles..."

# Rol GitHub Actions
aws iam delete-role-policy \
  --role-name "${PROJECT}-github-actions-role" \
  --policy-name "${PROJECT}-github-actions-policy" 2>/dev/null || true
aws iam delete-role --role-name "${PROJECT}-github-actions-role" 2>/dev/null || true

# Rol task execution
aws iam detach-role-policy \
  --role-name "${PROJECT}-task-exec-role" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" 2>/dev/null || true
aws iam delete-role --role-name "${PROJECT}-task-exec-role" 2>/dev/null || true

# Rol instancia + instance profile
aws iam remove-role-from-instance-profile \
  --instance-profile-name "${PROJECT}-ecs-profile" \
  --role-name "${PROJECT}-ecs-instance-role" 2>/dev/null || true
aws iam delete-instance-profile \
  --instance-profile-name "${PROJECT}-ecs-profile" 2>/dev/null || true
aws iam detach-role-policy \
  --role-name "${PROJECT}-ecs-instance-role" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role" 2>/dev/null || true
aws iam delete-role --role-name "${PROJECT}-ecs-instance-role" 2>/dev/null || true

# OIDC — es único por cuenta y puede estar compartido con otros repositorios
echo ""
read -r -p "¿Eliminar el OIDC provider de GitHub Actions? (puede afectar otros repos de esta cuenta) [y/N] " CONFIRM
if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
  OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
  aws iam delete-openid-connect-provider \
    --open-id-connect-provider-arn "$OIDC_ARN" 2>/dev/null || true
  echo "  OIDC provider eliminado"
fi

# ── Red (esperar a que la instancia haya terminado del todo) ───────────────────
echo ""
echo "Red..."
VPC_ID=$(_q "$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=${PROJECT}-vpc" \
  --query "Vpcs[0].VpcId" --output text --region "$REGION")")

if [[ -n "$VPC_ID" ]]; then
  # Security groups (excepto el default de la VPC)
  SG_IDS=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" \
    --output text --region "$REGION" 2>/dev/null || echo "")
  for SG in $SG_IDS; do
    aws ec2 delete-security-group --group-id "$SG" --region "$REGION" 2>/dev/null || true
  done

  # Subnets
  SUBNET_IDS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "Subnets[].SubnetId" --output text --region "$REGION" 2>/dev/null || echo "")
  for SN in $SUBNET_IDS; do
    aws ec2 delete-subnet --subnet-id "$SN" --region "$REGION" 2>/dev/null || true
  done

  # Route tables (no la main)
  RT_IDS=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" \
    --output text --region "$REGION" 2>/dev/null || echo "")
  for RT in $RT_IDS; do
    ASSOC_IDS=$(aws ec2 describe-route-tables --route-table-ids "$RT" \
      --query "RouteTables[0].Associations[].RouteTableAssociationId" \
      --output text --region "$REGION" 2>/dev/null || echo "")
    for ASSOC in $ASSOC_IDS; do
      aws ec2 disassociate-route-table --association-id "$ASSOC" --region "$REGION" 2>/dev/null || true
    done
    aws ec2 delete-route-table --route-table-id "$RT" --region "$REGION" 2>/dev/null || true
  done

  # Internet gateways
  IGW_IDS=$(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
    --query "InternetGateways[].InternetGatewayId" \
    --output text --region "$REGION" 2>/dev/null || echo "")
  for IGW in $IGW_IDS; do
    aws ec2 detach-internet-gateway \
      --internet-gateway-id "$IGW" --vpc-id "$VPC_ID" --region "$REGION" 2>/dev/null || true
    aws ec2 delete-internet-gateway \
      --internet-gateway-id "$IGW" --region "$REGION" 2>/dev/null || true
  done

  # VPC
  aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION"
  echo "  VPC $VPC_ID eliminada"
fi

echo ""
echo "════════════════════════════════════════════════════"
echo " Todos los recursos eliminados"
echo "════════════════════════════════════════════════════"
