# CI/CD con GitHub Actions, AWS ECS y Azure ACI

Pipeline de CI/CD que despliega una página nginx en dos clouds en paralelo.
Cualquier `git push` a `main` detecta qué servicios han cambiado y despliega **solo los afectados**.

```
GitHub (push a main)
        │
        ├─► deploy-aws.yml             → ECR → ECS EC2 → http://<ec2-ip>
        └─► deploy-azure.yml           → ACR → ACI      → http://silence-web.westeurope.azurecontainer.io
            deploy-azure-students.yml  ↗ (alternativa sin Service Principal — Azure for Students)
```

---

## Estructura del proyecto

```
.
├── infra/
│   ├── setup-aws.sh        # Crea toda la infraestructura AWS (ejecutar una vez)
│   └── destroy-aws.sh      # Elimina todos los recursos AWS
├── services/
│   └── web/
│       ├── Dockerfile
│       └── index.html
└── .github/workflows/
    ├── deploy-aws.yml
    ├── deploy-azure.yml           # cuenta de pago (Service Principal)
    └── deploy-azure-students.yml  # Azure for Students (bearer token)
```

---

## Parte 1 — AWS (AWS CLI + ECS EC2)

### Paso 1 — Preparar el entorno

Elige según dónde quieras ejecutar los comandos. Ambas opciones funcionan tanto con cuenta personal como con AWS Academy.

#### Opción A — AWS CloudShell (sin instalación)

Terminal bash en el navegador con AWS CLI ya instalado y credenciales configuradas automáticamente.

**Cuenta personal:**
1. Entra en la [consola AWS](https://console.aws.amazon.com) → selecciona la región **EU (Ireland)** en el menú superior derecho
2. Abre CloudShell: icono **`>_`** en la barra superior

**AWS Academy:**
1. Entra en [AWS Academy](https://awsacademy.instructure.com) → inicia tu laboratorio → **AWS Management Console**
2. Abre CloudShell: icono **`>_`** en la barra superior

En ambos casos, clona el repositorio y verifica las credenciales:

```bash
git clone https://github.com/ignaciogros/aws-azure-cicd.git
cd aws-azure-cicd
aws sts get-caller-identity   # verifica que funciona
```

#### Opción B — Terminal local (AWS CLI v2 instalado)

**Requisitos:** [Docker Desktop](https://www.docker.com/products/docker-desktop/) y AWS CLI v2.

**Instalar AWS CLI v2 en Windows** (PowerShell o cmd):

```powershell
winget install --id Amazon.AWSCLI
```

Cierra y vuelve a abrir el terminal para que el PATH se actualice.

**Cuenta personal** — configura con tus credenciales de IAM:

```bash
aws configure
# Introduce: Access Key ID, Secret Access Key, región (eu-west-1), formato (json)
aws sts get-caller-identity   # verifica que funciona
```

**AWS Academy** — copia los valores del panel "AWS Details" del laboratorio:

```bash
aws configure set aws_access_key_id <valor>
aws configure set aws_secret_access_key <valor>
aws configure set aws_session_token <valor>
aws configure set region eu-west-1
aws sts get-caller-identity   # verifica que funciona
```

> **Limitación de AWS Academy:** las credenciales cambian en cada sesión de laboratorio — hay que repetir este paso cada vez. Además, el entorno puede bloquear la creación de OIDC providers, lo que impide que GitHub Actions se autentique sin credenciales estáticas (ver Paso 3).

### Paso 2 — Crear la infraestructura

Edita las variables al principio de `infra/setup-aws.sh`:

```bash
GITHUB_ORG="tu-usuario-github"
GITHUB_REPO="nombre-del-repositorio"
```

Luego ejecuta el script:

```bash
bash infra/setup-aws.sh
```

El script crea todos los recursos (VPC, EC2, ECS, ECR, IAM, OIDC) y es idempotente:
se puede relanzar sin duplicar nada. Anota los **outputs** que aparecen al final:

| Output | Qué es |
|--------|--------|
| `ec2_public_ip` | IP donde estará la aplicación |
| `github_actions_role_arn` | ARN que usará GitHub para autenticarse |
| `aws_account_id` | ID de tu cuenta AWS |

### Paso 3 — Configurar GitHub

El script muestra los valores exactos al finalizar. Configura según tu entorno:

**Cuenta AWS normal — OIDC (sin secretos):**

Settings → Secrets and variables → Actions → **Variables** → New repository variable:

| Nombre | Valor |
|--------|-------|
| `AWS_ACCOUNT_ID` | `aws_account_id` del output del script |
| `AWS_ROLE_ARN` | `github_actions_role_arn` del output del script |

**AWS Academy — credenciales estáticas:**

Settings → Secrets and variables → Actions → **Secrets** → New repository secret:

| Nombre | Origen (panel "AWS Details" del lab) |
|--------|--------------------------------------|
| `AWS_ACCESS_KEY_ID` | `aws_access_key_id` |
| `AWS_SECRET_ACCESS_KEY` | `aws_secret_access_key` |
| `AWS_SESSION_TOKEN` | `aws_session_token` |

Y como variable (no secret):

| Nombre | Valor |
|--------|-------|
| `AWS_ACCOUNT_ID` | `aws_account_id` del output del script |

> **Academy:** estas credenciales expiran al finalizar la sesión de laboratorio.
> Actualiza los tres secrets en GitHub cada vez que reinicies el lab antes de hacer push.

### Paso 4 — Primer despliegue

```bash
git push origin main
```

El workflow `deploy-aws.yml` ejecuta estos pasos:
1. **Detect changes** — compara el commit actual con el anterior; si un directorio de `services/` cambió, lo añade a la lista
2. **Build & push** — construye la imagen Docker y la sube a ECR con el SHA del commit como tag
3. **Register task definition** — descarga la definición actual de ECS, sustituye la imagen y registra una nueva revisión
4. **Update service** — ordena a ECS que use la nueva revisión
5. **Wait** — espera a que el servicio se estabilice
6. **Verify** — hace un `curl` a la IP pública para confirmar que responde

### Paso 5 — Verificar

```bash
# Abre en el navegador:
http://<ec2_public_ip>

# Estado del servicio ECS:
aws ecs describe-services \
  --cluster silence-cluster \
  --services silence-web-svc \
  --query "services[0].{estado:status,deseadas:desiredCount,ejecutando:runningCount}"

# Logs del contenedor:
aws logs tail /ecs/silence-web --follow
```

### Gestionar la instancia (para no gastar crédito)

La IP pública puede cambiar al detener/arrancar la instancia si no usas Elastic IP.

```bash
# Obtener el ID de la instancia
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=silence-ecs-node" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)

aws ec2 stop-instances  --instance-ids $INSTANCE_ID   # parar (deja de facturar compute)
aws ec2 start-instances --instance-ids $INSTANCE_ID   # arrancar

# IP actual tras el arranque:
aws ec2 describe-instances --instance-ids $INSTANCE_ID \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text
```

### Destruir la infraestructura

```bash
bash infra/destroy-aws.sh
```

---

## Parte 2 — Azure (Azure CLI + ACI)

Azure no usa scripts de setup; la infraestructura se crea con `az` directamente. Más simple para empezar.

### Requisitos previos

- [Azure CLI](https://learn.microsoft.com/es-es/cli/azure/install-azure-cli)
- Cuenta Azure activa (Azure for Students es suficiente)

### Paso 1 — Iniciar sesión

```bash
az login
az account show   # verifica que estás en la suscripción correcta
```

### Paso 2 — Crear la infraestructura base (una sola vez)

**Bash (Linux / macOS / Azure Cloud Shell):**

```bash
RG="rg-silence"
LOCATION="westeurope"
ACR_NAME="silenceacr202506"   # debe ser globalmente único en Azure

az group create --name $RG --location $LOCATION
az acr create --resource-group $RG --name $ACR_NAME --sku Basic --admin-enabled true

az provider register --namespace Microsoft.ContainerInstance
az provider show --namespace Microsoft.ContainerInstance --query registrationState
# Espera hasta que diga "Registered"
```

**PowerShell (Windows):**

```powershell
$RG = "rg-silence"
$LOCATION = "westeurope"
$ACR_NAME = "silenceacr202506"   # debe ser globalmente único en Azure

az group create --name $RG --location $LOCATION
az acr create --resource-group $RG --name $ACR_NAME --sku Basic --admin-enabled true

az provider register --namespace Microsoft.ContainerInstance
az provider show --namespace Microsoft.ContainerInstance --query registrationState
# Espera hasta que diga "Registered"
```

> `--admin-enabled true` es necesario para que ACI pueda autenticarse con el ACR.

### Paso 3 — Autenticación para GitHub Actions

Elige la opción según tu tipo de cuenta. **Solo debe estar activo un workflow de Azure a la vez** — deshabilita el otro desde GitHub → Actions → (nombre del workflow) → ··· → Disable.

---

#### Opción A — Cuenta de pago: Service Principal → `deploy-azure.yml`

**Bash / Azure Cloud Shell** (redefine `$RG` si es una sesión nueva):

```bash
RG="rg-silence"
SUBSCRIPTION_ID=$(az account show --query id --output tsv)

az ad sp create-for-rbac \
  --name "sp-github-silence" \
  --role contributor \
  --scopes "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG" \
  --json-auth
```

**PowerShell:**

```powershell
$SUBSCRIPTION_ID = $(az account show --query id --output tsv)

az ad sp create-for-rbac `
  --name "sp-github-silence" `
  --role contributor `
  --scopes "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG" `
  --json-auth
```

Copia el JSON completo. En GitHub → **Settings → Secrets and variables → Actions → New repository secret**:

| Nombre | Valor |
|--------|-------|
| `AZURE_CREDENTIALS` | el JSON completo del comando anterior |

Desactiva `deploy-azure-students.yml` si estaba habilitado.

---

#### Opción B — Azure for Students: bearer token → `deploy-azure-students.yml`

Azure for Students no permite crear Service Principals (`az ad sp create-for-rbac` devuelve "Insufficient privileges"). En su lugar se usa un bearer token temporal y credenciales admin del ACR.

> **Importante:** el bearer token caduca en ~1 hora. Hay que regenerarlo antes de cada sesión de trabajo en la que vayas a hacer push.

**1. Obtén los valores necesarios** (Bash / Azure Cloud Shell / PowerShell):

```bash
# ID de suscripción
az account show --query id --output tsv

# Credenciales admin del ACR
az acr credential show -n silenceacr202506 --query username -o tsv
az acr credential show -n silenceacr202506 --query "passwords[0].value" -o tsv

# Bearer token (caduca ~1 h — regenerar antes de cada push)
az account get-access-token --resource https://management.azure.com/ --query accessToken --output tsv
```

**2. Configura GitHub:**

Settings → Secrets and variables → Actions → **Variables** → New repository variable:

| Nombre | Valor |
|--------|-------|
| `AZURE_SUBSCRIPTION_ID` | resultado del primer comando |

Settings → Secrets and variables → Actions → **Secrets** → New repository secret:

| Nombre | Valor |
|--------|-------|
| `REGISTRY_LOGIN_SERVER` | `silenceacr202506.azurecr.io` |
| `REGISTRY_USERNAME` | resultado del segundo comando |
| `REGISTRY_PASSWORD` | resultado del tercer comando |
| `AZURE_BEARER_TOKEN` | resultado del cuarto comando |

Desactiva `deploy-azure.yml` si estaba habilitado.

---

### Paso 4 — Ajustar el workflow

Edita el archivo que vayas a usar (`.github/workflows/deploy-azure.yml` o `deploy-azure-students.yml`) y cambia las variables `env:` si es necesario:

```yaml
env:
  ACR_NAME:       silenceacr202506   # el nombre que elegiste para el ACR (solo en deploy-azure.yml)
  RESOURCE_GROUP: rg-silence
  LOCATION:       westeurope
  PROJECT:        silence
```

> El DNS del contenedor será `silence-web.westeurope.azurecontainer.io`. Si ese nombre
> ya está ocupado en Azure (es global), cambia `PROJECT` a otro valor único.

### Paso 5 — Primer despliegue

```bash
git push origin main
```

Ambos workflows ejecutan la misma secuencia lógica:
1. **Detect changes** — misma lógica que el workflow de AWS
2. **Login / autenticación** — `azure/login@v2` con SP (opción A) o credenciales directas de ACR + bearer token (opción B)
3. **Build & push** — imagen a ACR con el SHA del commit
4. **Delete + create ACI** — ACI no admite actualización in-place; se elimina y recrea
5. **Verify** — `curl` al DNS público

### Paso 6 — Verificar

```bash
# URL pública (estable entre despliegues — el DNS label no cambia)
http://silence-web.westeurope.azurecontainer.io

# Estado del contenedor:
az container show \
  --resource-group rg-silence \
  --name silence-web-aci \
  --query "{estado:instanceView.state, fqdn:ipAddress.fqdn}" \
  --output table

# Logs:
az container logs --resource-group rg-silence --name silence-web-aci
```

### Gestionar el contenedor (para no gastar crédito)

```bash
az container stop  --resource-group rg-silence --name silence-web-aci
az container start --resource-group rg-silence --name silence-web-aci
```

---

## Comparativa AWS vs. Azure

| | AWS (ECS EC2) | Azure ACI — cuenta pago | Azure ACI — for Students |
|---|---|---|---|
| Infraestructura | AWS CLI (setup-aws.sh) | Azure CLI | Azure CLI |
| Autenticación CI/CD | OIDC (sin secretos) | Service Principal (JSON) | Bearer token temporal (~1 h) |
| Registro de imágenes | ECR | ACR | ACR (admin habilitado) |
| Ejecución | ECS sobre EC2 t2.micro | Azure Container Instances | Azure Container Instances |
| URL | IP de la instancia EC2 | DNS estable (`*.azurecontainer.io`) | DNS estable (`*.azurecontainer.io`) |
| Actualización | `update-service` (in-place) | Delete + create (sin estado) | Delete + create (sin estado) |
| Workflow | `deploy-aws.yml` | `deploy-azure.yml` | `deploy-azure-students.yml` |
| Coste Free Tier | t2.micro gratis 12 meses | ACI cobra por segundo de ejecución | ACI cobra por segundo de ejecución |

---

## Cómo añadir un nuevo servicio

1. Crea `services/<nombre>/Dockerfile`
2. En AWS: duplica los bloques de ECR, task definition y service en `setup-aws.sh` para el nuevo nombre, y vuelve a ejecutarlo
3. En Azure: no hay cambios en infraestructura — el workflow crea el contenedor automáticamente
4. El siguiente push que modifique `services/<nombre>/` lo desplegará en ambas plataformas
