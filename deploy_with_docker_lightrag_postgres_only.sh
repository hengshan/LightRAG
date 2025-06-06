#!/bin/bash

# LightRAG Docker Deployment Script (Using Existing Ollama)
# Uses existing ollama-gpu container + DeepSeek API
# Only deploys PostgreSQL + LightRAG

set -e

echo "🚀 Starting LightRAG Deployment (with existing Ollama)..."
echo "🧠 LLM: DeepSeek API (fast, cloud-based)"
echo "🔍 Embeddings: Existing ollama-gpu container (reusing GPU)"

# Step 1: Check if existing ollama-gpu container is running
echo "🔍 Checking existing Ollama container..."
if docker ps --format 'table {{.Names}}' | grep -q "^ollama-gpu$"; then
    echo "✅ ollama-gpu container is running!"
    # Test if Ollama is responsive
    if curl -s http://localhost:11434/api/version > /dev/null; then
        OLLAMA_VERSION=$(curl -s http://localhost:11434/api/version | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
        echo "   📊 Ollama version: $OLLAMA_VERSION"
        echo "   🚀 Reusing existing GPU-enabled Ollama container"
    else
        echo "❌ ollama-gpu container exists but not responding on port 11434"
        exit 1
    fi
else
    echo "❌ ollama-gpu container not found or not running!"
    echo "💡 Please start your Ollama container first:"
    echo "   docker run -d --name ollama-gpu --gpus all -p 11434:11434 -v ollama-data:/root/.ollama -e OLLAMA_HOST=0.0.0.0 ollama/ollama:latest"
    exit 1
fi

# Step 2: Check if bge-m3 model is available
echo "🔍 Checking for bge-m3 embedding model..."
if docker exec ollama-gpu ollama list | grep -q "bge-m3"; then
    echo "✅ bge-m3 model already available in existing container"
else
    echo "📥 Pulling bge-m3 embedding model to existing container..."
    docker exec ollama-gpu ollama pull bge-m3:latest
    echo "✅ bge-m3 model downloaded successfully!"
fi

# Step 3: Check DeepSeek API connectivity
echo "🌐 Testing DeepSeek API connection..."
if curl -s -f -H "Authorization: Bearer ${LLM_BINDING_API_KEY:-$(grep LLM_BINDING_API_KEY .env | cut -d'=' -f2)}" \
   "https://api.deepseek.com/v1/models" > /dev/null; then
    echo "✅ DeepSeek API connection successful"
else
    echo "❌ DeepSeek API connection failed. Check your API key in .env file"
    exit 1
fi

# Step 4: Clean up any existing LightRAG containers (but keep ollama-gpu)
echo "🧹 Cleaning up existing LightRAG containers..."
# Stop and remove specific containers, not ollama-gpu
docker stop lightrag-app lightrag-postgres 2>/dev/null || true
docker rm lightrag-app lightrag-postgres 2>/dev/null || true
echo "✅ Cleanup complete (kept ollama-gpu container)"

# Step 5: Create Docker Compose file for LightRAG + PostgreSQL only
echo "🏗️  Creating Docker Compose configuration..."
cat > docker-compose-lightrag-only.yml << EOF
version: '3.8'

services:
  postgres:
    container_name: lightrag-postgres
    build:
      context: .
      dockerfile: Dockerfile.postgres-age-vector
    environment:
      POSTGRES_DB: lightrag
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d lightrag"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  lightrag:
    container_name: lightrag-app
    image: ghcr.io/hkuds/lightrag:latest
    environment:
      # Server configuration
      HOST: 0.0.0.0
      PORT: 9621
      
      # LLM configuration (DeepSeek API)
      LLM_BINDING: openai
      LLM_MODEL: deepseek-chat
      LLM_BINDING_HOST: https://api.deepseek.com/v1
      LLM_BINDING_API_KEY: \${LLM_BINDING_API_KEY}
      
      # Embedding configuration (existing Ollama container)
      EMBEDDING_BINDING: ollama
      EMBEDDING_MODEL: bge-m3:latest
      EMBEDDING_BINDING_HOST: http://host.docker.internal:11434
      
      # PostgreSQL configuration
      POSTGRES_HOST: postgres
      POSTGRES_PORT: 5432
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DATABASE: lightrag
      
      # Storage configuration
      LIGHTRAG_KV_STORAGE: PGKVStorage
      LIGHTRAG_VECTOR_STORAGE: PGVectorStorage
      LIGHTRAG_GRAPH_STORAGE: PGGraphStorage
      LIGHTRAG_DOC_STATUS_STORAGE: PGDocStatusStorage
    ports:
      - "9621:9621"
    volumes:
      - lightrag_data:/app/data
    depends_on:
      postgres:
        condition: service_healthy
    restart: unless-stopped
    extra_hosts:
      - "host.docker.internal:host-gateway"

volumes:
  postgres_data:
  lightrag_data:
EOF

# Step 6: Build and start LightRAG stack (PostgreSQL + LightRAG only)
echo "🏗️  Building and starting LightRAG stack..."
docker-compose -f docker-compose-lightrag-only.yml up --build -d

# Step 7: Wait for services to be healthy
echo "⏳ Waiting for services to start..."
sleep 15

# Step 8: Check service status
echo "📊 Checking service status..."
docker-compose -f docker-compose-lightrag-only.yml ps

# Step 9: Wait for PostgreSQL to be ready
echo "⏳ Waiting for PostgreSQL to be ready..."
timeout 60s bash -c 'until docker exec lightrag-postgres pg_isready -U postgres -d lightrag; do sleep 2; done'

# Step 10: Verify extensions are loaded
echo "✅ Verifying PostgreSQL extensions..."
docker exec lightrag-postgres psql -d lightrag -U postgres -c "SELECT extname FROM pg_extension WHERE extname IN ('age', 'vector');"

# Step 11: Verify configuration
echo "✅ Verifying hybrid configuration..."
docker exec lightrag-app sh -c 'echo "LLM Host: $LLM_BINDING_HOST" && echo "Embedding Host: $EMBEDDING_BINDING_HOST"'

# Step 12: Test connection to existing Ollama
echo "✅ Testing connection to existing Ollama container..."
if docker exec lightrag-app curl -s http://host.docker.internal:11434/api/version > /dev/null; then
    echo "✅ LightRAG can reach existing ollama-gpu container!"
else
    echo "⚠️  Warning: LightRAG may have trouble reaching ollama-gpu container"
    echo "💡 If issues occur, check Docker network connectivity"
fi

echo ""
echo "🎉 LightRAG deployment complete (using existing Ollama)!"
echo ""
echo "📊 Architecture:"
echo "   ├── Existing: ollama-gpu (GPU-enabled, reused)"
echo "   ├── New: lightrag-postgres (PostgreSQL with AGE + pgvector)"
echo "   └── New: lightrag-app (LightRAG application)"
echo ""
echo "📡 Services available at:"
echo "   - LightRAG API & WebUI: http://localhost:9621"
echo "   - Existing Ollama: http://localhost:11434"
echo "   - PostgreSQL: localhost:5432"
echo ""
echo "⚙️  Configuration:"
echo "   - LLM: DeepSeek API (deepseek-chat)"
echo "   - Embeddings: Existing ollama-gpu (bge-m3:latest) with GPU"
echo "   - Database: PostgreSQL with AGE + pgvector"
echo ""
echo "🔧 To check logs:"
echo "   docker-compose -f docker-compose-lightrag-only.yml logs -f lightrag"
echo ""
echo "🛑 To stop (keeps ollama-gpu running):"
echo "   docker-compose -f docker-compose-lightrag-only.yml down"
echo ""
echo "🚀 Ready to use:"
echo "   1. WebUI: http://localhost:9621/webui/"
echo "   2. API Docs: http://localhost:9621/docs"
echo "   3. Upload documents and start querying!"
echo ""
echo "💡 Benefits of this setup:"
echo "   ✅ Reuses existing GPU-enabled Ollama container"
echo "   ✅ No duplicate Ollama instances"
echo "   ✅ Efficient resource usage"
echo "   ✅ Fast DeepSeek API for LLM" 