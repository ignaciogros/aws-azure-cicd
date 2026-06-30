# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project does

CI/CD pipeline that deploys a containerized nginx service to **AWS ECS (EC2)** and **Azure ACI** in parallel on every push to `main`. Both workflows share the same change-detection logic: only `services/` subdirectories that changed between `github.event.before` and `github.sha` are deployed. A `workflow_dispatch` or the very first push (before SHA `0000...`) always deploys everything.

## Key commands

**AWS infra — provision (run once):**
```bash
bash infra/setup-aws.sh
```

**AWS infra — destroy:**
```bash
bash infra/destroy-aws.sh
```

**Local Docker build (test before pushing):**
```bash
docker build -t silence-web services/web/
docker run -p 8080:80 silence-web
```

**Verify AWS deployment:**
```bash
aws ecs describe-services --cluster silence-cluster --services silence-web-svc \
  --query "services[0].{status:status,desired:desiredCount,running:runningCount}"
aws logs tail /ecs/silence-web --follow
```

**Verify Azure deployment:**
```bash
az container show --resource-group rg-silence --name silence-web-aci \
  --query "{state:instanceView.state,fqdn:ipAddress.fqdn}" --output table
az container logs --resource-group rg-silence --name silence-web-aci
```

## Architecture

### Infra (AWS — shell script)

`infra/setup-aws.sh` creates all AWS resources with AWS CLI and is fully idempotent (safe to re-run). Resources are created in this order: VPC → IGW → Subnet → Route table → Security group → IAM roles → OIDC provider → ECR → ECS cluster → CloudWatch log group → EC2 instance → ECS task definition → ECS service.

`infra/destroy-aws.sh` tears everything down in reverse. It prompts before deleting the OIDC provider because it is shared account-wide and may affect other repositories.

Three IAM roles:
- `silence-ecs-instance-role` — attached to the EC2 node so the ECS agent can register with the cluster
- `silence-task-exec-role` — used by ECS tasks to pull images from ECR and write to CloudWatch
- `silence-github-actions-role` — assumed by GitHub Actions via OIDC (no stored Access Keys)

**IAM propagation delay:** `setup-aws.sh` sleeps 12 s after creating the instance profile before launching the EC2 instance. This is required — AWS EC2 rejects instance launches with an unrecognized instance profile if IAM hasn't propagated yet.

**Task definition ownership:** the ECS service is created pointing to the first task definition revision. GitHub Actions registers a new revision on each deploy and calls `update-service`. The setup script never re-registers the task definition if one already exists, so re-running setup won't revert a live deployment.

ECR keeps only the last 5 images (lifecycle policy set in `setup-aws.sh`).

### CI/CD workflows

Both workflows follow the same two-job pattern:

1. `detect-changes` — outputs a JSON array of service names (e.g. `["web"]`)
2. `build-and-deploy` — matrix job, one runner per changed service

**AWS (`deploy-aws.yml`):** authenticates via OIDC → builds image → pushes to ECR with `github.sha` as tag → downloads current ECS task definition, patches the image field, registers new revision → calls `update-service` → waits for stability → curls the EC2 public IP.

**Azure (`deploy-azure.yml`):** authenticates via Service Principal JSON (`AZURE_CREDENTIALS` secret) → builds image → pushes to ACR → **deletes then recreates** the ACI container (ACI has no in-place update API) → curls `http://$PROJECT-$SERVICE.$LOCATION.azurecontainer.io`.

**Azure for Students (`deploy-azure-students.yml`):** no requiere Service Principal (Azure for Students no permite `az ad sp create-for-rbac`). Autentica el push a ACR con credenciales admin del registro almacenadas como secretos (`REGISTRY_*`). Despliega en ACI llamando directamente a la ARM REST API con `curl` usando un bearer token temporal (`AZURE_BEARER_TOKEN`). El ARM DELETE es asíncrono, por lo que el workflow espera hasta 404 antes de recrear el contenedor. **El bearer token caduca en ~1 h**: hay que regenerarlo con `az account get-access-token` antes de cada sesión de trabajo. Solo debe estar activo un workflow de Azure a la vez — deshabilitar el otro desde la UI de GitHub Actions.

### GitHub configuration required

**AWS:**

| Type | Name | Value |
|------|------|-------|
| Variable | `AWS_ACCOUNT_ID` | output of `bash infra/setup-aws.sh` |

**Azure — cuenta de pago (`deploy-azure.yml`):**

| Type | Name | Value |
|------|------|-------|
| Secret | `AZURE_CREDENTIALS` | JSON from `az ad sp create-for-rbac --json-auth` |

**Azure for Students (`deploy-azure-students.yml`):**

| Type | Name | Value |
|------|------|-------|
| Variable | `AZURE_SUBSCRIPTION_ID` | `az account show --query id --output tsv` |
| Secret | `REGISTRY_LOGIN_SERVER` | `az acr show -n <acr-name> --query loginServer -o tsv` |
| Secret | `REGISTRY_USERNAME` | `az acr credential show -n <acr-name> --query username -o tsv` |
| Secret | `REGISTRY_PASSWORD` | `az acr credential show -n <acr-name> --query "passwords[0].value" -o tsv` |
| Secret | `AZURE_BEARER_TOKEN` | `az account get-access-token --resource https://management.azure.com/ --query accessToken --output tsv` (**expira ~1 h**) |

The Azure variables (`ACR_NAME`, `RESOURCE_GROUP`, `LOCATION`, `PROJECT`) are hardcoded in `deploy-azure.yml` and `deploy-azure-students.yml` `env:` blocks — edit them there if the Azure setup differs.

### Adding a new service

1. Create `services/<name>/Dockerfile`
2. For AWS: duplicate the ECR, task definition, and ECS service blocks in `setup-aws.sh` for the new name, then re-run the script
3. For Azure: no infra changes needed — the workflow creates the ACI container automatically
