#!/bin/bash

# LightRAG Docker Deployment Script (Hybrid: DeepSeek + Ollama)
# DeepSeek API for LLM, Containerized Ollama for Embeddings
# Optimal setup: Fast API + Local GPU embeddings

set -e

echo "🚀 Starting LightRAG Hybrid Deployment..."
echo "🧠 LLM: DeepSeek API (fast, cloud-based)"
echo "🔍 Embeddings: Containerized Ollama (local GPU)"

# Step 1: Check if NVIDIA Container Toolkit is available
echo "🔍 Checking GPU support for embeddings..."
if ! docker run --rm --gpus all nvidia/cuda:11.0-base nvidia-smi &>/dev/null; then
    echo "❌ NVIDIA Container Toolkit not available. GPU support disabled."
    echo "💡 Install NVIDIA Container Toolkit for GPU acceleration"
fi

# Step 2: Check DeepSeek API connectivity
echo "🌐 Testing DeepSeek API connection..."
if curl -s -f -H "Authorization: Bearer ${LLM_BINDING_API_KEY:-$(grep LLM_BINDING_API_KEY .env | cut -d'=' -f2)}" \
   "https://api.deepseek.com/v1/models" > /dev/null; then
    echo "✅ DeepSeek API connection successful"
else
    echo "❌ DeepSeek API connection failed. Check your API key in .env file"
    exit 1
fi

# Step 3: Build and start the hybrid stack
echo "🏗️  Building and starting hybrid LightRAG stack..."
docker-compose -f docker-compose-with-ollama.yml up --build -d

# Step 4: Wait for services to be healthy
echo "⏳ Waiting for services to start..."
sleep 15

# Step 5: Check service status
echo "📊 Checking service status..."
docker-compose -f docker-compose-with-ollama.yml ps

# Step 6: Wait for PostgreSQL to be ready
echo "⏳ Waiting for PostgreSQL to be ready..."
timeout 60s bash -c 'until docker exec lightrag-postgres pg_isready -U postgres -d lightrag; do sleep 2; done'

# Step 7: Wait for Ollama to be ready
echo "⏳ Waiting for Ollama to be ready..."
timeout 60s bash -c 'until docker exec lightrag-ollama ollama list &>/dev/null; do sleep 2; done'

# Step 8: Pull embedding model only (LLM uses DeepSeek API)
echo "📥 Pulling embedding model in Ollama container..."
echo "   - Pulling bge-m3:latest (embedding model for local GPU)..."
docker exec lightrag-ollama ollama pull bge-m3:latest
echo "   ✅ LLM will use DeepSeek API (no local model needed)"

# Step 9: Verify extensions are loaded
echo "✅ Verifying PostgreSQL extensions..."
docker exec lightrag-postgres psql -d lightrag -U postgres -c "SELECT extname FROM pg_extension WHERE extname IN ('age', 'vector');"

# Step 10: Verify configuration
echo "✅ Verifying hybrid configuration..."
docker exec lightrag-app sh -c 'echo "LLM Host: $LLM_BINDING_HOST" && echo "Embedding Host: $EMBEDDING_BINDING_HOST"'

# Step 11: Verify Ollama has embedding model
echo "✅ Verifying Ollama embedding model..."
docker exec lightrag-ollama ollama list

echo ""
echo "🎉 LightRAG Hybrid deployment complete!"
echo ""
echo "📡 Services available at:"
echo "   - LightRAG API & WebUI: http://localhost:9621"
echo "   - Ollama (embeddings): http://localhost:11434"
echo "   - PostgreSQL: localhost:5432"
echo ""
echo "⚙️  Configuration:"
echo "   - LLM: DeepSeek API ($(docker exec lightrag-app printenv LLM_MODEL))"
echo "   - Embeddings: Local Ollama (bge-m3:latest) with GPU"
echo "   - Database: PostgreSQL with AGE + pgvector"
echo ""
echo "🔧 To check logs:"
echo "   docker-compose -f docker-compose-with-ollama.yml logs -f lightrag"
echo ""
echo "🛑 To stop:"
echo "   docker-compose -f docker-compose-with-ollama.yml down"
echo ""
echo "🚀 Ready to use:"
echo "   1. WebUI: http://localhost:9621/webui/"
echo "   2. API Docs: http://localhost:9621/docs"
echo "   3. Upload documents and start querying!" 