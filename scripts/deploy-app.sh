#!/usr/bin/env bash
# deploy-app.sh — Deploys retail-store-sample-app to project-bedrock-cluster
set -euo pipefail

log()   { echo "[$(date '+%H:%M:%S')] $1"; }
error() { echo "[$(date '+%H:%M:%S')] ERROR: $1" >&2; exit 1; }

# ── Config ────────────────────────────────────────────────────────────────────
CLUSTER_NAME="project-bedrock-cluster"
REGION="us-east-1"
NAMESPACE="retail-app"
CHART_VERSION="1.6.2"
INFRA_DIR="${INFRA_DIR:-../project-bedrock-infra/terraform}"

# ── Preflight ─────────────────────────────────────────────────────────────────
command -v kubectl &>/dev/null || error "kubectl not installed"
command -v helm    &>/dev/null || error "helm not installed"
command -v aws     &>/dev/null || error "aws CLI not installed"
aws sts get-caller-identity &>/dev/null || error "AWS credentials not configured"

# ── Step 1: Configure kubectl ─────────────────────────────────────────────────
log "Configuring kubectl for $CLUSTER_NAME..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"
kubectl get nodes || error "Cannot reach cluster"

# ── Step 2: Create namespace ──────────────────────────────────────────────────
log "Creating $NAMESPACE namespace..."
kubectl apply -f k8s/namespace.yaml

# ── Step 3: Read Terraform outputs ────────────────────────────────────────────
log "Reading infrastructure outputs..."
cd "$INFRA_DIR"

MYSQL_HOST=$(terraform output -raw mysql_host 2>/dev/null) \
  || error "Cannot read mysql_host — run terraform apply in project-bedrock-infra first"
PG_HOST=$(terraform output -raw postgresql_host)
DYNAMO_TABLE=$(terraform output -raw dynamodb_carts_table)
MYSQL_SECRET_ARN=$(terraform output -raw mysql_secret_arn)
PG_SECRET_ARN=$(terraform output -raw postgresql_secret_arn)

cd -

log "MySQL host:      $MYSQL_HOST"
log "PostgreSQL host: $PG_HOST"
log "DynamoDB table:  $DYNAMO_TABLE"

# ── Step 4: Create Kubernetes Secrets from AWS Secrets Manager ────────────────
log "Creating Kubernetes Secrets from AWS Secrets Manager..."

# MySQL credentials for catalog service
MYSQL_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "$MYSQL_SECRET_ARN" \
  --region "$REGION" \
  --query SecretString \
  --output text)

kubectl create secret generic retail-store-catalog-db \
  --namespace "$NAMESPACE" \
  --from-literal=host="$MYSQL_HOST" \
  --from-literal=username="$(echo "$MYSQL_SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['username'])")" \
  --from-literal=password="$(echo "$MYSQL_SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")" \
  --dry-run=client -o yaml | kubectl apply -f -

# PostgreSQL credentials for orders service
PG_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "$PG_SECRET_ARN" \
  --region "$REGION" \
  --query SecretString \
  --output text)

kubectl create secret generic retail-store-orders-db \
  --namespace "$NAMESPACE" \
  --from-literal=host="$PG_HOST" \
  --from-literal=username="$(echo "$PG_SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['username'])")" \
  --from-literal=password="$(echo "$PG_SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")" \
  --dry-run=client -o yaml | kubectl apply -f -

log "Kubernetes Secrets created ✓"

# ── Step 5: Install AWS Load Balancer Controller ──────────────────────────────
log "Installing AWS Load Balancer Controller..."

VPC_ID=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --query "cluster.resourcesVpcConfig.vpcId" \
  --output text)

helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update

helm upgrade --install aws-load-balancer-controller \
  eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --wait \
  --timeout 5m

log "AWS Load Balancer Controller installed ✓"

# ── Step 6: Deploy retail-store-sample-app ────────────────────────────────────
log "Deploying retail-store-sample-app v${CHART_VERSION}..."

helm upgrade --install retail-store \
  oci://public.ecr.aws/aws-containers/retail-store-sample-app \
  --version "$CHART_VERSION" \
  --namespace "$NAMESPACE" \
  --values helm/values.yaml \
  --set carts.env.CARTS_DYNAMODB_TABLE_NAME="$DYNAMO_TABLE" \
  --wait \
  --timeout 10m

log "retail-store-sample-app deployed ✓"

# ── Step 7: Apply ingress and network policies ────────────────────────────────
log "Applying Ingress and NetworkPolicies..."
kubectl apply -f k8s/ingress.yaml
kubectl apply -f k8s/network-policies.yaml
log "Ingress and NetworkPolicies applied ✓"

# ── Step 8: Wait for ALB ─────────────────────────────────────────────────────
log "Waiting for ALB to be provisioned (~2 minutes)..."
ALB_HOSTNAME=""
for i in {1..24}; do
  ALB_HOSTNAME=$(kubectl get ingress retail-store-ingress \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [[ -n "$ALB_HOSTNAME" ]] && break
  log "Attempt $i/24 — waiting 15s..."
  sleep 15
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo  "         retail-store-sample-app Deployment"
echo "║  Cluster:      $CLUSTER_NAME"
echo "║  Namespace:    $NAMESPACE"
echo "║  Chart:        v$CHART_VERSION"
echo "║  ALB URL:      http://$ALB_HOSTNAME"
echo "║  MySQL:        $MYSQL_HOST"
echo "║  PostgreSQL:   $PG_HOST"
echo "║  DynamoDB:     $DYNAMO_TABLE"


log "Deploy complete ✓"
log "App available at: http://$ALB_HOSTNAME"
