#!/usr/bin/env bash
docker rm -f qwen-brain 2>/dev/null || true
docker run -d --name qwen-brain \
    --gpus all --ipc host --network host \
    --restart unless-stopped \
    -e MODEL="/models/qwen35-122b" \
    -e VLLM_NVFP4_GEMM_BACKEND=marlin \
    -e VLLM_ALLOW_LONG_MAX_MODEL_LEN="1" \
    -e VLLM_FLASHINFER_ALLREDUCE_BACKEND=trtllm \
    -e VLLM_USE_FLASHINFER_MOE_FP4="0" \
    -e VLLM_MARLIN_USE_ATOMIC_ADD="1" \
    -v /opt/models:/models \
    avarok/dgx-vllm-nvfp4-kernel:v23 \
    serve \
        --served-model-name qwen35-122b \
        --host 0.0.0.0 --port 8000 \
        --gpu-memory-utilization 0.60 \
        --max-model-len 65536 \
        --kv-cache-dtype fp8 \
        --trust-remote-code \
        --enable-auto-tool-choice \
        --tool-call-parser qwen3_coder \
        --reasoning-parser qwen3 \
        --enable-prefix-caching \
        --max-num-seqs 4
echo "qwen-brain started"
