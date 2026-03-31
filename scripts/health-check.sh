#!/bin/bash
# NOTE: This script is outdated. Use scripts/check_stack.sh instead.
# This file checks ASR, TTS, pgvector, and other services no longer in the stack.
# Comprehensive System Health Check
# Usage: ./health-check.sh [--detailed] [--telegram]
# Checks: vLLM, ASR, TTS, Docker containers, GPU, Database, Message Queue

set -e

VERBOSE=false
TELEGRAM=false

if [[ "$1" == "--detailed" ]]; then
    VERBOSE=true
fi

if [[ "$1" == "--telegram" ]]; then
    TELEGRAM=true
fi

echo "========================================"
echo "  SYSTEM HEALTH CHECK - $(date)"
echo "========================================"
echo ""

# Function to check HTTP endpoint
check_http() {
    local name=$1
    local url=$2
    local port=$3
    
    if curl -sf "$url" >/dev/null 2>&1; then
        local status=$(curl -sf "$url" 2>/dev/null | head -c 100)
        echo "✓ $name - Port $port - OK"
        if [[ "$VERBOSE" == true ]]; then
            echo "  Response: $status"
        fi
        return 0
    else
        echo "✗ $name - Port $port - FAILED"
        return 1
    fi
}

# Function to check Docker container
check_docker() {
    local name=$1
    local container=$2
    
    if docker ps --filter "name=$container" --filter "status=running" >/dev/null 2>&1; then
        local container_id=$(docker ps --filter "name=$container" --filter "status=running" --format "{{.ID}}" | head -1)
        echo "✓ Docker container - $name - Running"
        if [[ "$VERBOSE" == true ]]; then
            echo "  Container ID: ${container_id:0:12}"
            local mem=$(docker inspect --format='{{.Memory}}' "$container_id" 2>/dev/null)
            if [[ -n "$mem" && "$mem" != "0" ]]; then
                echo "  Memory: $((mem / 1024 / 1024 / 1024)) GB"
            fi
        fi
        return 0
    else
        echo "✗ Docker container - $name - NOT RUNNING"
        return 1
    fi
}

# Function to check GPU
check_gpu() {
    if nvidia-smi | grep -q "VLLM::EngineCore"; then
        local gpu_usage=$(nvidia-smi | grep "VLLM::EngineCore" | awk '{print $10}' | tr -d 'MiB')
        echo "✓ GPU vLLM process - Running ($gpu_usage GB)"
        return 0
    else
        echo "✗ GPU vLLM process - NOT FOUND"
        return 1
    fi
}

# Function to check PostgreSQL
check_postgres() {
    if docker exec pgvector pg_isready -U postgres >/dev/null 2>&1; then
        local db_count=$(docker exec pgvector psql -U postgres -d agent_memory -t -c "SELECT COUNT(*) FROM lessons;" 2>/dev/null | tr -d ' ')
        echo "✓ PostgreSQL (pgvector) - Ready ($db_count lessons indexed)"
        return 0
    else
        echo "✗ PostgreSQL (pgvector) - NOT RESPONDING"
        return 1
    fi
}

# Function to check OpenClaw gateway
check_openclaw_gateway() {
    if curl -sf "http://127.0.0.1:18789/" >/dev/null 2>&1; then
        echo "✓ OpenClaw Gateway - Port 18789 - OK"
        return 0
    else
        echo "✗ OpenClaw Gateway - Port 18789 - NOT RESPONDING"
        return 1
    fi
}

# Function to check Telegram channel
check_telegram() {
    local channel_status=$(curl -sf "http://127.0.0.1:18789/status" 2>/dev/null | grep -o '"status":"[^"]*"' | head -1)
    if [[ -n "$channel_status" ]]; then
        echo "✓ Telegram Channel - Status: $channel_status"
        return 0
    else
        echo "✗ Telegram Channel - Not responding"
        return 1
    fi
}

# Main checks
echo "Core Services:"
echo "--------------"
ALL_OK=true

check_http "vLLM (Brain)" "http://localhost:8000/v1/models" 8000 || ALL_OK=false
check_http "ASR Server" "http://localhost:8002/health" 8002 || ALL_OK=false
check_http "TTS Server" "http://localhost:8003/health" 8003 || ALL_OK=false
check_docker "ASR" "asr-server" || ALL_OK=false
check_docker "TTS" "tts-server" || ALL_OK=false
check_gpu || ALL_OK=false
check_postgres || ALL_OK=false
check_openclaw_gateway || ALL_OK=false
check_telegram || ALL_OK=false

echo ""
echo "========================================"
if [[ "$ALL_OK" == true ]]; then
    echo "  ALL SYSTEMS OPERATIONAL ✓"
else
    echo "  SOME SYSTEMS UNHEALTHY ⚠"
fi
echo "========================================"

# Send to Telegram if requested
if [[ "$TELEGRAM" == true ]]; then
    status_text="System Health: "
    if [[ "$ALL_OK" == true ]]; then
        status_text+="All systems operational"
    else
        status_text+="Some systems unhealthy"
    fi
    
    # Send message via OpenClaw message tool would go here
    echo "Status would be sent to Telegram: $status_text"
fi

exit 0
