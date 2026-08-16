# project-bedrock-app
The Application repo for project bedrock(Tinyuka 2025)

Application deployment repository for the **project-bedrock** capstone.

Deploys the [AWS Retail Store Sample App](https://github.com/aws-containers/retail-store-sample-app) (v1.6.2) to the `project-bedrock-cluster` EKS cluster using the upstream Helm chart with custom values overriding in-cluster databases with managed AWS services.

---

## Repository Structure

```
project-bedrock-app/
├── helm/
│   └── values.yaml          ← Helm overrides (RDS/DynamoDB endpoints)
├── k8s/
│   ├── namespace.yaml        ← retail-app namespace
│   ├── ingress.yaml          ← ALB Ingress for ui service
│   └── network-policies.yaml ← pod-to-pod traffic restrictions
├── scripts/
│   └── deploy-app.sh         ← local deployment script
└── .github/
    └── workflows/
        └── app-deploy.yml    ← CI/CD pipeline
```

---

## Prerequisites

The infrastructure repo (`project-bedrock-infra`) must be deployed first. This repo reads Terraform outputs to get RDS endpoints and Secrets Manager ARNs.

```bash
# Verify infrastructure is deployed
cd ../project-bedrock-infra/terraform
terraform output
```

Tools required:
```
aws CLI    >= 2.x
kubectl    >= 1.34
helm       >= 3.x
python3
```

---

## Deployment — Single Command (Bonus 5.1)

```bash
helm upgrade --install retail-store \
  oci://public.ecr.aws/aws-containers/retail-store-sample-app \
  --version 1.6.2 \
  --namespace retail-app \
  --create-namespace \
  --values helm/values.yaml \
  --set carts.env.CARTS_DYNAMODB_TABLE_NAME=project-bedrock-carts \
  --wait \
  --timeout 10m
```

---

## Deployment — Full Script

For a complete deployment including secrets, ALB controller, and ingress:

```bash
chmod +x scripts/deploy-app.sh
./scripts/deploy-app.sh
```

The script performs:

```
1. Configure kubectl for project-bedrock-cluster
2. Create retail-app namespace
3. Read Terraform outputs (RDS hosts, Secrets Manager ARNs)
4. Create Kubernetes Secrets from AWS Secrets Manager
5. Install AWS Load Balancer Controller via Helm
6. Deploy retail-store v1.6.2 via Helm with custom values
7. Apply Ingress and NetworkPolicies
8. Wait for ALB and print the app URL
```

---

## Data Layer

| Service | In-Cluster (disabled) | Managed AWS |
|---|---|---|
| Catalog | MySQL pod | RDS MySQL 8.0 (`db.t3.micro`) |
| Orders | PostgreSQL pod | RDS PostgreSQL 16.3 (`db.t3.micro`) |
| Carts | Redis pod | DynamoDB (`PAY_PER_REQUEST`) |
| RabbitMQ | ✅ stays in-cluster | — |

Database credentials are stored in **AWS Secrets Manager** and injected into pods via Kubernetes Secrets at deploy time. No credentials are stored in `values.yaml` or any committed file.

---

## CI/CD Pipeline

| Trigger | Action |
|---|---|
| Pull Request | Validates YAML manifests + posts result as PR comment |
| Merge to main | Deploys retail-store to EKS |
| workflow_dispatch | Manual deploy |

### GitHub Secrets Required

```
AWS_ACCESS_KEY_ID       ← IAM user with EKS + Secrets Manager access
AWS_SECRET_ACCESS_KEY
```

### GitHub Environment

Create a `production` environment in repo Settings for deployment protection.

---

## Network Policies (Bonus 5.4)

Applied via `k8s/network-policies.yaml`. Default deny-all with selective allows:

```
ui       → catalog, carts, orders, checkout, assets   ✅
checkout → orders, carts, rabbitmq                    ✅
orders   → postgresql (RDS port 5432), rabbitmq       ✅
catalog  → mysql (RDS port 3306)                      ✅
carts    → dynamodb (port 443 HTTPS)                  ✅
catalog  → orders                                     ❌ blocked
orders   → catalog                                    ❌ blocked
```

---

## Pod Self-Healing Demonstration (Bonus 5.5)

```bash
# 1 — Record running pods
kubectl get pods -n retail-app

# 2 — Delete a pod
kubectl delete pod <ui-pod-name> -n retail-app

# 3 — Watch Kubernetes reschedule it automatically
kubectl get pods -n retail-app -w
```

Kubernetes reschedules a replacement within ~30 seconds. The deployment's `replicaCount: 2` ensures the other replica continues serving traffic during recovery.

---

## Teardown

```bash
# Remove the Helm release
helm uninstall retail-store -n retail-app

# Remove ingress and network policies
kubectl delete -f k8s/

# Remove namespace (deletes all remaining resources)
kubectl delete namespace retail-app

# Remove AWS Load Balancer Controller
helm uninstall aws-load-balancer-controller -n kube-system
```

Then destroy infrastructure in `project-bedrock-infra`:

```bash
cd ../project-bedrock-infra
./scripts/deploy.sh destroy
```

---

## Related Repository

Infrastructure: [gb-in-the-cloud/project-bedrock-infra](https://github.com/gb-in-the-cloud/project-bedrock-infra)
