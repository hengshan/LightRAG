#!/bin/bash

# Default server type to gunicorn (production)
SERVER_TYPE=${LIGHTRAG_SERVER_TYPE:-gunicorn}

# Ensure logs directory exists
mkdir -p /app/logs

echo "Starting LightRAG with server type: $SERVER_TYPE"

if [ "$SERVER_TYPE" = "dev" ] || [ "$SERVER_TYPE" = "development" ]; then
    echo "Starting development server (single worker)..."
    exec python -m lightrag.api.lightrag_server
elif [ "$SERVER_TYPE" = "gunicorn" ] || [ "$SERVER_TYPE" = "production" ]; then
    echo "Starting production server with Gunicorn (multiple workers)..."
    exec lightrag-gunicorn
else
    echo "Error: Unknown server type '$SERVER_TYPE'. Use 'dev' or 'gunicorn'"
    exit 1
fi 