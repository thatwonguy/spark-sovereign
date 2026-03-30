#!/usr/bin/env python3
"""
spark-memory — MCP server for pgvector memory access
Exposes memory recall and lesson storage to OpenClaw/NemoClaw.
"""

import json
import sys
from pathlib import Path

# Add spark-sovereign to path
sys.path.insert(0, str(Path(__file__).parent))

from agent.memory import recall, store_lesson, recall_as_context


def main():
    """Simple JSON-RPC server for memory access."""
    import asyncio
    
    async def handle_request(msg: dict) -> dict:
        method = msg.get("method")
        params = msg.get("params", {})
        
        if method == "recall":
            query = params.get("query", "")
            top_k = params.get("top_k", 5)
            domain = params.get("domain")
            
            lessons, web_results = recall(query, top_k=top_k, domain=domain)
            
            return {
                "result": {
                    "lessons": [
                        {"content": c, "outcome": o, "importance": i, "source": s, "score": sc}
                        for c, o, i, s, sc in lessons
                    ],
                    "web_results": [
                        {"query": q, "result": r, "url": u, "confidence": c, "score": sc}
                        for q, r, u, c, sc in web_results
                    ]
                }
            }
        
        elif method == "store_lesson":
            content = params.get("content")
            outcome = params.get("outcome", "success")
            domain = params.get("domain", "general")
            importance = params.get("importance", 0.8)
            
            lesson_id = store_lesson(content, outcome, domain, importance, "agent")
            return {"result": {"id": lesson_id, "stored": True}}
        
        elif method == "recall_context":
            query = params.get("query", "")
            top_k = params.get("top_k", 5)
            domain = params.get("domain")
            
            context = recall_as_context(query, top_k=top_k, domain=domain)
            return {"result": {"context": context}}
        
        else:
            return {"error": f"Unknown method: {method}"}
    
    async def read_requests():
        while True:
            try:
                line = await asyncio.to_thread(sys.stdin.readline)
                if not line:
                    break
                
                # Parse Content-Length
                if line.startswith("Content-Length:"):
                    length = int(line.strip().split(": ")[1])
                    
                    # Read body
                    body = await asyncio.to_thread(sys.stdin.read, length)
                    
                    # Handle request
                    msg = json.loads(body)
                    response = await handle_request(msg)
                    
                    # Send response
                    resp_json = json.dumps(response)
                    response_line = f"Content-Length: {len(resp_json)}\r\n\r\n{resp_json}"
                    await asyncio.to_thread(sys.stdout.write, response_line)
                    await asyncio.to_thread(sys.stdout.flush)
                    
            except Exception as e:
                print(f"Error: {e}", file=sys.stderr)
                break
    
    asyncio.run(read_requests())


if __name__ == "__main__":
    main()
