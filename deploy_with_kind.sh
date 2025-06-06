#!/bin/bash

# LightRAG Kind Deployment Script (Hybrid: DeepSeek + Host Ollama + K8s)
# 
# 🎯 WHAT THIS SCRIPT DOES:
# This script deploys LightRAG using a hybrid approach:
# - DeepSeek API for LLM (fast, cloud-based)
# - Ollama with GPU on Docker host (reliable GPU access)
# - PostgreSQL + LightRAG in Kind cluster (learn Kubernetes)
# - Network: K8s services connect to host Ollama

set -e

NAMESPACE=lightrag
KIND_CLUSTER_NAME=lightrag-cluster
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

echo "🚀 Starting LightRAG Hybrid Kind Deployment..."
echo "🧠 LLM: DeepSeek API (fast, cloud-based)"
echo "🔍 Embeddings: Ollama with GPU on Docker host"
echo "💾 Database: PostgreSQL with pgvector + AGE in Kubernetes"
echo "🏗️  Platform: Hybrid (Docker host + Kind cluster)"
echo ""

# Function to print colored messages
print_info() {
    echo "ℹ️  $1"
}

print_success() {
    echo "✅ $1"
}

print_warning() {
    echo "⚠️  $1"
}

print_error() {
    echo "❌ $1"
}

# Step 1: Check prerequisites
echo "🔍 Checking prerequisites..."

# Check if Kind is installed
if ! command -v kind &> /dev/null; then
    print_error "Kind is not installed. Please install Kind first:"
    echo "  # On Linux:"
    echo "  curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64"
    echo "  chmod +x ./kind"
    echo "  sudo mv ./kind /usr/local/bin/kind"
    exit 1
fi

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    print_error "kubectl is not installed. Please install kubectl first:"
    echo "  # On Linux:"
    echo "  curl -LO https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    echo "  chmod +x kubectl"
    echo "  sudo mv kubectl /usr/local/bin/"
    exit 1
fi

# Check if Docker is running
if ! docker info &> /dev/null; then
    print_error "Docker is not running. Please start Docker Desktop or Docker daemon."
    exit 1
fi

# Check GPU support
if nvidia-smi &> /dev/null; then
    print_success "NVIDIA GPU detected and accessible!"
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
else
    print_warning "No NVIDIA GPU detected. Ollama will run on CPU."
fi

print_success "All prerequisites are installed!"

# Step 2: Check DeepSeek API key
echo ""
echo "🔑 Checking DeepSeek API configuration..."

if [ -f ".env" ]; then
    source .env
elif [ -f "../.env" ]; then
    source ../.env
fi

if [ -z "$LLM_BINDING_API_KEY" ]; then
    print_warning "LLM_BINDING_API_KEY not found in .env file"
    read -s -p "Enter your DeepSeek API key: " LLM_BINDING_API_KEY
    if [ -z "$LLM_BINDING_API_KEY" ]; then
        print_error "DeepSeek API key is required!"
        exit 1
    fi
    export LLM_BINDING_API_KEY=$LLM_BINDING_API_KEY
fi

# Test DeepSeek API connection
print_info "Testing DeepSeek API connection..."
if curl -s -f -H "Authorization: Bearer $LLM_BINDING_API_KEY" \
   "https://api.deepseek.com/v1/models" > /dev/null; then
    print_success "DeepSeek API connection successful"
else
    print_error "DeepSeek API connection failed. Check your API key."
    exit 1
fi

# Step 3: Start Ollama with GPU on Docker host
echo ""
echo "🦙 Setting up Ollama with GPU on Docker host..."

# Check if ollama-gpu container already exists
if docker ps -a --format 'table {{.Names}}' | grep -q "^ollama-gpu$"; then
    print_info "Ollama container already exists"
    if docker ps --format 'table {{.Names}}' | grep -q "^ollama-gpu$"; then
        print_info "Ollama is already running"
    else
        print_info "Starting existing Ollama container..."
        docker start ollama-gpu
    fi
else
    print_info "Creating new Ollama container with GPU support..."
    if nvidia-smi &> /dev/null; then
        docker run -d --name ollama-gpu --gpus all -p 11434:11434 \
               -v ollama-data:/root/.ollama -e OLLAMA_HOST=0.0.0.0 \
               ollama/ollama:latest
    else
        docker run -d --name ollama-gpu -p 11434:11434 \
               -v ollama-data:/root/.ollama -e OLLAMA_HOST=0.0.0.0 \
               ollama/ollama:latest
    fi
fi

# Wait for Ollama to be ready
print_info "Waiting for Ollama to be ready..."
for i in {1..30}; do
    if curl -s http://localhost:11434/api/version > /dev/null; then
        break
    fi
    sleep 2
done

if curl -s http://localhost:11434/api/version > /dev/null; then
    print_success "Ollama is ready on Docker host!"
    OLLAMA_VERSION=$(curl -s http://localhost:11434/api/version | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
    echo "   Version: $OLLAMA_VERSION"
else
    print_error "Ollama failed to start. Check Docker logs: docker logs ollama-gpu"
    exit 1
fi

# Pull embedding model if not already present
print_info "Checking for bge-m3 model..."
if docker exec ollama-gpu ollama list | grep -q "bge-m3"; then
    print_success "bge-m3 model already available"
else
    print_info "Pulling bge-m3 embedding model (this may take 5-10 minutes)..."
    docker exec ollama-gpu ollama pull bge-m3:latest
    print_success "bge-m3 model downloaded successfully!"
fi

# Step 4: Create Kind cluster
echo ""
echo "🏗️  Setting up Kind cluster..."

# Check if cluster already exists
if kind get clusters | grep -q "^${KIND_CLUSTER_NAME}$"; then
    print_info "Kind cluster '${KIND_CLUSTER_NAME}' already exists"
    read -p "Do you want to delete and recreate it? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Deleting existing cluster..."
        kind delete cluster --name $KIND_CLUSTER_NAME
    else
        print_info "Using existing cluster"
    fi
fi

# Create Kind cluster if it doesn't exist
if ! kind get clusters | grep -q "^${KIND_CLUSTER_NAME}$"; then
    print_info "Creating Kind cluster..."
    
    # Create Kind config for hybrid setup
    cat > /tmp/kind-config.yaml << EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${KIND_CLUSTER_NAME}
nodes:
- role: control-plane
  # Port mappings for external access
  extraPortMappings:
  - containerPort: 30080
    hostPort: 9621
    protocol: TCP
  - containerPort: 30082
    hostPort: 5432
    protocol: TCP
EOF

    kind create cluster --config /tmp/kind-config.yaml
    print_success "Kind cluster created successfully!"
    
    # Wait for cluster to be ready
    print_info "Waiting for cluster to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=300s
else
    # Set kubectl context to our cluster
    kubectl cluster-info --context kind-${KIND_CLUSTER_NAME}
fi

print_success "Kind cluster is ready!"

# Step 5: Create namespace
echo ""
echo "📦 Setting up Kubernetes namespace..."

if ! kubectl get namespace $NAMESPACE &> /dev/null; then
    print_info "Creating namespace '$NAMESPACE'..."
    kubectl create namespace $NAMESPACE
else
    print_info "Namespace '$NAMESPACE' already exists"
fi

print_success "Namespace ready!"

# Step 6: Deploy PostgreSQL with pgvector + AGE
echo ""
echo "🐘 Deploying PostgreSQL with pgvector + AGE..."

# Build custom PostgreSQL image with both extensions
print_info "Building custom PostgreSQL image with AGE + pgvector extensions..."
docker build -f Dockerfile.postgres-age-vector -t lightrag-postgres-age-vector:latest .

# Load the custom image into Kind cluster
print_info "Loading custom PostgreSQL image into Kind cluster..."
kind load docker-image lightrag-postgres-age-vector:latest --name $KIND_CLUSTER_NAME

# Create PostgreSQL deployment with proper permissions for persistent volumes
print_info "Creating PostgreSQL deployment with security context for Kind compatibility..."
cat > /tmp/postgres-deployment.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      # Fix permissions for PostgreSQL data directory
      securityContext:
        runAsUser: 999
        runAsGroup: 999
        fsGroup: 999
      containers:
      - name: postgres
        image: lightrag-postgres-age-vector:latest
        imagePullPolicy: Never
        env:
        - name: POSTGRES_DB
          value: lightrag
        - name: POSTGRES_USER
          value: postgres
        - name: POSTGRES_PASSWORD
          value: postgres
        # Use subdirectory to avoid permission conflicts
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: postgres-storage
          mountPath: /var/lib/postgresql/data
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "1Gi" 
            cpu: "500m"
      volumes:
      - name: postgres-storage
        persistentVolumeClaim:
          claimName: postgres-pvc
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: $NAMESPACE
spec:
  selector:
    app: postgres
  ports:
  - port: 5432
    targetPort: 5432
    nodePort: 30082
  type: NodePort
EOF

kubectl apply -f /tmp/postgres-deployment.yaml

print_info "Waiting for PostgreSQL to be ready..."
kubectl wait --for=condition=ready pod -l app=postgres -n $NAMESPACE --timeout=300s

# The extensions are already installed and initialized via init-postgres-age.sql
print_success "PostgreSQL with pgvector + AGE is ready!"
print_info "Extensions installed via init-postgres-age.sql:"
print_info "  ✅ pgvector (vector similarity search)"
print_info "  ✅ AGE (Apache AGE for graph operations)"

# Step 7: Get host IP for Kind cluster to reach Ollama
echo ""
echo "🌐 Configuring network connectivity..."

# Get the host IP that Kind can reach
if command -v ip &> /dev/null; then
    HOST_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
elif command -v hostname &> /dev/null; then
    HOST_IP=$(hostname -I | awk '{print $1}')
else
    HOST_IP="host.docker.internal"
fi

print_info "Host IP for Ollama connection: $HOST_IP"

# Test connection from within Kind network
print_info "Testing Ollama connectivity from Kind network..."
if kubectl run test-ollama --image=curlimages/curl --rm -i --restart=Never -- \
   curl -s http://${HOST_IP}:11434/api/version > /dev/null 2>&1; then
    print_success "Ollama is reachable from Kind cluster!"
else
    print_warning "Ollama may not be reachable from Kind. Using host.docker.internal as fallback."
    HOST_IP="host.docker.internal"
fi

# Step 8: Deploy LightRAG
echo ""
echo "🚀 Deploying LightRAG application..."

cat > /tmp/lightrag-deployment.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lightrag
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: lightrag
  template:
    metadata:
      labels:
        app: lightrag
    spec:
      containers:
      - name: lightrag
        image: ghcr.io/hkuds/lightrag:latest
        ports:
        - containerPort: 9621
        env:
        - name: HOST
          value: "0.0.0.0"
        - name: PORT
          value: "9621"
        - name: LLM_BINDING
          value: "openai"
        - name: LLM_MODEL
          value: "deepseek-chat"
        - name: LLM_BINDING_HOST
          value: "https://api.deepseek.com/v1"
        - name: LLM_BINDING_API_KEY
          value: "$LLM_BINDING_API_KEY"
        - name: EMBEDDING_BINDING
          value: "ollama"
        - name: EMBEDDING_MODEL
          value: "bge-m3:latest"
        - name: EMBEDDING_BINDING_HOST
          value: "http://${HOST_IP}:11434"
        - name: POSTGRES_HOST
          value: "postgres"
        - name: POSTGRES_PORT
          value: "5432"
        - name: POSTGRES_USER
          value: "postgres"
        - name: POSTGRES_PASSWORD
          value: "postgres"
        - name: POSTGRES_DATABASE
          value: "lightrag"
        - name: LIGHTRAG_KV_STORAGE
          value: "PGKVStorage"
        - name: LIGHTRAG_VECTOR_STORAGE
          value: "PGVectorStorage"
        - name: LIGHTRAG_GRAPH_STORAGE
          value: "PGGraphStorage"
        - name: LIGHTRAG_DOC_STATUS_STORAGE
          value: "PGDocStatusStorage"
        volumeMounts:
        - name: rag-storage
          mountPath: /app/data/rag_storage
        - name: inputs-storage
          mountPath: /app/data/inputs
        resources:
          requests:
            memory: "1Gi"
            cpu: "500m"
          limits:
            memory: "4Gi"
            cpu: "2000m"
      volumes:
      - name: rag-storage
        persistentVolumeClaim:
          claimName: lightrag-rag-pvc
      - name: inputs-storage
        persistentVolumeClaim:
          claimName: lightrag-inputs-pvc
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: lightrag-rag-pvc
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: lightrag-inputs-pvc
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
---
apiVersion: v1
kind: Service
metadata:
  name: lightrag
  namespace: $NAMESPACE
spec:
  selector:
    app: lightrag
  ports:
  - port: 9621
    targetPort: 9621
    nodePort: 30080
  type: NodePort
EOF

kubectl apply -f /tmp/lightrag-deployment.yaml

print_info "Waiting for LightRAG to be ready..."
kubectl wait --for=condition=ready pod -l app=lightrag -n $NAMESPACE --timeout=300s

print_success "LightRAG deployment complete!"

# Step 9: Display information
echo ""
echo "🎉 LightRAG Hybrid deployment complete!"
echo ""
echo "📊 Architecture:"
echo "   ├── Docker Host:"
echo "   │   └── Ollama with GPU (bge-m3 embeddings)"
echo "   └── Kind Cluster ($KIND_CLUSTER_NAME):"
echo "       ├── PostgreSQL (pgvector + AGE)"
echo "       └── LightRAG (connects to host Ollama)"
echo ""
echo "📡 Services available at:"
echo "   - LightRAG WebUI: http://localhost:9621"
echo "   - Ollama API: http://localhost:11434"
echo "   - PostgreSQL: localhost:5432"
echo ""
echo "⚙️  Configuration:"
echo "   - LLM: DeepSeek API (deepseek-chat) via OpenAI-compatible binding"
echo "   - Embeddings: Ollama (bge-m3:latest) with GPU on host"
echo "   - Database: PostgreSQL with pgvector + AGE in K8s"
echo "   - Graph Storage: PostgreSQL AGE extension"
echo "   - Platform: Hybrid (Docker + Kubernetes)"
echo ""
echo "🔧 Useful commands:"
echo "   # Check K8s pods:"
echo "   kubectl get pods -n $NAMESPACE"
echo ""
echo "   # Check Ollama on host:"
echo "   docker logs ollama-gpu"
echo "   docker exec ollama-gpu ollama list"
echo ""
echo "   # View logs:"
echo "   kubectl logs -f deployment/lightrag -n $NAMESPACE"
echo "   kubectl logs -f deployment/postgres -n $NAMESPACE"
echo ""
echo "   # Cleanup:"
echo "   kind delete cluster --name $KIND_CLUSTER_NAME"
echo "   docker stop ollama-gpu && docker rm ollama-gpu"
echo ""
echo "🚀 Ready to use:"
echo "   1. WebUI: http://localhost:9621/webui/"
echo "   2. API Docs: http://localhost:9621/docs"
echo "   3. Upload documents and start querying!"
echo ""
echo "💡 Benefits of this hybrid setup:"
echo "   ✅ Reliable GPU access for embeddings"
echo "   ✅ Learn Kubernetes concepts with PostgreSQL + LightRAG"
echo "   ✅ Production-like architecture (external services + K8s)" 