#!/bin/bash
# =============================================================================
# 03-k3s.sh — Install k3s and deploy the todo-app
#
# PDF Requirements satisfied:
#   REQ-13: Kubernetes cluster in private subnet (k3s-vm has no public IP)
#   REQ-14: MONGODB_URL injected as env var from a Kubernetes Secret
#   REQ-15: wizexercise.txt baked into the image (created in Dockerfile)
#   REQ-16: validate.sh runs "kubectl exec <pod> -- cat /app/wizexercise.txt"
#   REQ-17: cluster-admin ClusterRoleBinding + privileged: true (both intentional)
#   REQ-18: Ingress via nginx (Azure LB blocked by CloudLabs public IP policy)
#   REQ-19: kubectl available — demo via az vm run-command
#
# WHY k3s INSTEAD OF AKS:
#   CloudLabs enforces an Azure Policy that denies all publicIPAddresses.
#   AKS always creates a public IP for outbound NAT — this is blocked.
#   k3s provides the full Kubernetes API (kubectl, RBAC, Ingress, Secrets)
#   on a single VM with zero Azure networking dependencies.
#
# INTENTIONAL WEAK CONFIGS (both required by the exercise — REQ-17):
#   - privileged: true  → container can escape to host via /proc/1/root
#   - cluster-admin     → pod's service account has unrestricted cluster access
#
# Arguments (positional, passed by deploy.sh):
#   $1 = ACR_SERVER   (e.g. wizacr12345.azurecr.io)
#   $2 = ACR_USER     (ACR admin username)
#   $3 = ACR_PASS     (ACR admin password)
#   $4 = MONGO_IP     (private IP of mongodb-vm, e.g. 10.0.1.4)
#   $5 = YOUR_NAME    (candidate name, already in image via build arg)
# =============================================================================
set -e

ACR_SERVER="$1"
ACR_USER="$2"
ACR_PASS="$3"
MONGO_IP="$4"
YOUR_NAME="$5"

export DEBIAN_FRONTEND=noninteractive
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "=== Installing k3s ==="

# Install k3s without Traefik (we use nginx ingress instead)
# --write-kubeconfig-mode 644 lets non-root users run kubectl
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode 644" sh -

echo "Waiting for k3s node to be Ready..."
until kubectl get nodes 2>/dev/null | grep -q "Ready"; do sleep 3; done
echo "k3s ready: $(kubectl get nodes --no-headers)"

echo ""
echo "=== Installing nginx Ingress Controller ==="
# nginx ingress satisfies REQ-18 (Kubernetes Ingress requirement)
# In a real cloud account without the public IP restriction, this would
# front an Azure Load Balancer with a public IP.
kubectl apply -f \
  https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.9.4/deploy/static/provider/baremetal/deploy.yaml

# Phase 1: wait for the pod to be CREATED (scheduled by k3s)
# kubectl wait fails with "no matching resources found" if the pod
# doesn't exist yet — which happens when called immediately after apply.
echo "Waiting for ingress-nginx pod to be created..."
for i in $(seq 1 40); do
  POD_COUNT=$(kubectl get pods -n ingress-nginx \
    -l app.kubernetes.io/component=controller \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "$POD_COUNT" -gt 0 ] && { echo "  Pod created after ${i}x3s"; break; }
  echo "  not yet (attempt $i/40)..."
  sleep 3
done

# Phase 2: wait for pod to be Ready
echo "Waiting for ingress-nginx pod to be Ready (up to 3 min)..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

# Phase 3: wait for admission webhook to come online
# Without this delay, applying Ingress gives:
#   "no endpoints available for ingress-nginx-controller-admission"
echo "Waiting 30s for admission webhook..."
sleep 30

echo ""
echo "=== Creating ACR image pull secret ==="
# Allow k3s to pull images from ACR (the candidate-built image — REQ-02)
echo "$ACR_PASS" | docker login "$ACR_SERVER" -u "$ACR_USER" --password-stdin 2>/dev/null || true
kubectl create secret docker-registry acr-secret \
  --docker-server="$ACR_SERVER" \
  --docker-username="$ACR_USER" \
  --docker-password="$ACR_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "=== Deploying Kubernetes manifests ==="

# -----------------------------------------------------------------------
# Secret: MongoDB connection string
# Stored as a Kubernetes Secret (not hardcoded in the Deployment).
# Injected as MONGODB_URL env var via secretKeyRef — REQ-14.
# -----------------------------------------------------------------------
kubectl apply -f - << EOF
apiVersion: v1
kind: Secret
metadata:
  name: mongodb-secret
type: Opaque
stringData:
  mongodb-url: "mongodb://wizadmin:WizPassword123!@${MONGO_IP}:27017/todos?authSource=admin"
EOF

# -----------------------------------------------------------------------
# ServiceAccount + ClusterRoleBinding
# INTENTIONAL WEAK CONFIG (REQ-17): cluster-admin grants unrestricted access
# to all Kubernetes API resources. In production, use least-privilege RBAC.
# -----------------------------------------------------------------------
kubectl apply -f - << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: todo-app-sa
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: todo-app-cluster-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: todo-app-sa
  namespace: default
EOF

# -----------------------------------------------------------------------
# Deployment
# INTENTIONAL WEAK CONFIG (REQ-17): privileged: true allows the container
# to access host kernel features and filesystem. In production, use
# securityContext with runAsNonRoot: true and drop all capabilities.
# -----------------------------------------------------------------------
kubectl apply -f - << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: todo-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: todo-app
  template:
    metadata:
      labels:
        app: todo-app
    spec:
      serviceAccountName: todo-app-sa
      imagePullSecrets:
      - name: acr-secret
      containers:
      - name: todo-app
        image: ${ACR_SERVER}/todo-app:latest
        ports:
        - containerPort: 3000
        securityContext:
          privileged: true        # INTENTIONAL WEAK CONFIG (REQ-17)
        env:
        - name: MONGODB_URL       # REQ-14: from Kubernetes Secret
          valueFrom:
            secretKeyRef:
              name: mongodb-secret
              key: mongodb-url
        - name: CANDIDATE_NAME
          value: "${YOUR_NAME}"
        readinessProbe:
          httpGet:
            path: /health
            port: 3000
          initialDelaySeconds: 10
          periodSeconds: 5
EOF

# -----------------------------------------------------------------------
# Service: ClusterIP routes traffic from Ingress to the pod
# -----------------------------------------------------------------------
kubectl apply -f - << EOF
apiVersion: v1
kind: Service
metadata:
  name: todo-app-svc
spec:
  selector:
    app: todo-app
  ports:
  - port: 80
    targetPort: 3000
EOF

# -----------------------------------------------------------------------
# Ingress: satisfies REQ-18 (Kubernetes Ingress)
# Applied with retry — admission webhook needs time after pod is Ready
# -----------------------------------------------------------------------
INGRESS_APPLIED=false
for attempt in 1 2 3 4 5; do
  echo "  Ingress apply attempt $attempt/5..."
  if kubectl apply -f - << INGRESSEOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: todo-app-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: todo-app-svc
            port:
              number: 80
INGRESSEOF
  then
    INGRESS_APPLIED=true
    echo "  Ingress created."
    break
  fi
  echo "  Admission webhook not ready yet — waiting 20s..."
  sleep 20
done
[ "$INGRESS_APPLIED" = "false" ] && echo "WARN: Ingress creation failed after 5 attempts"


echo ""
echo "=== Waiting for todo-app pod to be Ready ==="
kubectl rollout status deployment/todo-app --timeout=3m

echo ""
echo "=== Validating wizexercise.txt in running container ==="
# REQ-15 + REQ-16: prove the file exists inside the running container
POD=$(kubectl get pod -l app=todo-app -o name | head -1)
kubectl exec "$POD" -- cat /app/wizexercise.txt

echo ""
echo "=== Final cluster state ==="
kubectl get nodes,pods,svc,ingress -o wide

echo ""
echo "=== k3s deploy complete ==="
echo "  Weak configs: privileged=true + cluster-admin (REQ-17)"
echo "  Ingress: todo-app-ingress (REQ-18)"
echo "  MONGODB_URL: injected from Secret (REQ-14)"
