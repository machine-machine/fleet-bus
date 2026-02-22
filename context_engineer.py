#!/usr/bin/env python3
"""
Context Engineer — Fleet Context Pre-loader
Bundles relevant context for a task before an agent claims it.

Flow:
  1. Embed task payload via BGE-M3 (memory-embeddings:8000)
  2. Semantic search Qdrant (agent_memory) → top-10 relevant memories
  3. Fetch recent SpacetimeDB events + completed tasks
  4. Distill with Gemini Flash 3 → compact 2k-token bundle
  5. Write context.json to /tmp/context-{task_id}.json (+ Minio if configured)

Usage:
  python3 context_engineer.py <task_id> <task_type> <payload>
  # Or as module: context_engineer.run(task_id, task_type, payload)
"""

import json
import os
import sys
import time
import urllib.request
import urllib.error

# ── Config ────────────────────────────────────────────────────────────────────
EMBEDDINGS_URL   = os.getenv("EMBEDDINGS_URL",   "http://memory-embeddings:8000")
QDRANT_URL       = os.getenv("QDRANT_URL",        "http://memory-qdrant:6333")
QDRANT_COLL      = os.getenv("QDRANT_COLLECTION", "agent_memory")
STDB_URI         = os.getenv("SPACETIMEDB_URI",   "http://spacetimedb:3000")
STDB_TOKEN       = os.getenv("SPACETIMEDB_TOKEN", "")
GEMINI_KEY       = os.getenv("GEMINI_API_KEY",    "")
GEMINI_MODELS    = ["gemini-2.5-flash-lite", "gemini-2.0-flash-lite", "gemini-flash-lite-latest"]
CONTEXT_DIR      = "/tmp"
TOP_K_MEMORIES   = 8
TOP_K_TASKS      = 5


def _post(url: str, body: dict, headers: dict = None, timeout: int = 10) -> dict:
    data = json.dumps(body).encode()
    h = {"Content-Type": "application/json", **(headers or {})}
    req = urllib.request.Request(url, data=data, headers=h, method="POST")
    try:
        resp = urllib.request.urlopen(req, timeout=timeout)
        return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code} from {url}: {e.read().decode()[:200]}")


def _get(url: str, headers: dict = None, timeout: int = 8) -> dict:
    req = urllib.request.Request(url, headers=headers or {})
    resp = urllib.request.urlopen(req, timeout=timeout)
    return json.loads(resp.read())


# ── Step 1: Embed ─────────────────────────────────────────────────────────────

def embed(text: str) -> list:
    """Get BGE-M3 embedding for text."""
    result = _post(f"{EMBEDDINGS_URL}/embed", {"inputs": text})
    if isinstance(result, list) and result:
        vec = result[0] if isinstance(result[0], list) else result
        return vec
    raise RuntimeError(f"Unexpected embedding response: {str(result)[:100]}")


# ── Step 2: Qdrant semantic search ────────────────────────────────────────────

def search_memories(query: str, top_k: int = TOP_K_MEMORIES) -> list:
    """Search Qdrant agent_memory for semantically relevant memories."""
    try:
        vector = embed(query)
        result = _post(
            f"{QDRANT_URL}/collections/{QDRANT_COLL}/points/search",
            {
                "vector": {"name": "dense", "vector": vector},
                "limit": top_k,
                "with_payload": True,
                "score_threshold": 0.35,
            }
        )
        hits = result.get("result", [])
        memories = []
        for h in hits:
            payload = h.get("payload", {})
            memories.append({
                "score": round(h.get("score", 0), 3),
                "text": payload.get("text", payload.get("content", ""))[:300],
                "tags": payload.get("tags", payload.get("entities", [])),
                "ts": payload.get("timestamp", ""),
            })
        return memories
    except Exception as e:
        return [{"error": str(e), "text": "", "score": 0}]


# ── Step 3: SpacetimeDB recent context ────────────────────────────────────────

def get_stdb_context(task_type: str) -> dict:
    """Pull recent events + relevant completed tasks from SpacetimeDB."""
    if not STDB_URI or not STDB_TOKEN:
        return {"events": [], "recent_tasks": [], "note": "SpacetimeDB not configured"}

    headers = {"Authorization": f"Bearer {STDB_TOKEN}", "Content-Type": "application/json"}
    context = {"events": [], "recent_tasks": []}

    try:
        # Recent events (last 10)
        r = _post(f"{STDB_URI}/v1/database/fleet-bus/sql",
                  {"query": "SELECT agent_id, event_type, data FROM events ORDER BY id DESC LIMIT 10"},
                  headers=headers)
        rows = r.get("rows", [])
        context["events"] = [{"agent": row[0], "type": row[1], "data": str(row[2])[:80]} for row in rows]
    except Exception as e:
        context["events_error"] = str(e)

    try:
        # Recent completed tasks of same type
        r = _post(f"{STDB_URI}/v1/database/fleet-bus/sql",
                  {"query": f"SELECT id, task_type, assigned_to, result FROM tasks WHERE task_type = '{task_type}' AND state = 'done' ORDER BY completed_at DESC LIMIT {TOP_K_TASKS}"},
                  headers=headers)
        rows = r.get("rows", [])
        context["recent_tasks"] = [{"id": r[0], "type": r[1], "agent": r[2], "result": str(r[3])[:100]} for r in rows]
    except Exception as e:
        context["tasks_error"] = str(e)

    return context


# ── Step 4: Gemini Flash distillation ────────────────────────────────────────

DISTILL_PROMPT = """You are the Context Engineer for the M2O fleet (autonomous agent system).
Given: a task payload + raw retrieved memories + recent fleet events.
Produce a compact, structured context bundle that an agent can read in <500 tokens to understand:
- What already exists relevant to this task
- Key decisions already made that affect this task
- Warnings: known pitfalls, things that failed before, constraints
- Key facts: endpoints, credentials patterns, file paths, conventions

Output ONLY valid JSON matching this schema:
{
  "summary": "<2-3 sentence overview of relevant context>",
  "relevant_files": ["path/or/url", ...],
  "prior_decisions": ["concise decision + reason", ...],
  "warnings": ["concrete warning", ...],
  "key_facts": {"name": "value", ...},
  "related_task_ids": ["id", ...]
}

Be ruthlessly concise. No prose outside the JSON. Max 8 items per list."""


def distill(task_payload: str, task_type: str, memories: list, stdb: dict) -> dict:
    """Call Gemini Flash 3 to distill raw context into compact bundle."""
    if not GEMINI_KEY:
        return {
            "summary": "Context Engineer: Gemini API key not configured.",
            "relevant_files": [], "prior_decisions": [], "warnings": [],
            "key_facts": {}, "related_task_ids": [],
            "_distilled": False,
        }

    # Build input for Gemini
    raw = {
        "task": {"type": task_type, "payload": task_payload},
        "memories": memories[:TOP_K_MEMORIES],
        "fleet_events": stdb.get("events", [])[:5],
        "recent_similar_tasks": stdb.get("recent_tasks", [])[:3],
    }
    user_content = f"Task: {task_type}\nPayload: {task_payload}\n\nRaw context:\n{json.dumps(raw, indent=2)}"

    last_error = None
    for model in GEMINI_MODELS:
        url = (f"https://generativelanguage.googleapis.com/v1beta/models/"
               f"{model}:generateContent?key={GEMINI_KEY}")
        body = {
            "system_instruction": {"parts": [{"text": DISTILL_PROMPT}]},
            "contents": [{"role": "user", "parts": [{"text": user_content}]}],
            "generationConfig": {
                "temperature": 0.1,
                "maxOutputTokens": 900,
            },
        }
        try:
            result = _post(url, body, timeout=20)
            text = result["candidates"][0]["content"]["parts"][0]["text"]
            # Strip markdown fences if present
            import re
            m = re.search(r"```(?:json)?\s*([\s\S]+?)```", text)
            clean = m.group(1).strip() if m else text.strip()
            bundle = json.loads(clean)
            bundle["_distilled"] = True
            bundle["_model"] = model
            return bundle
        except RuntimeError as e:
            last_error = e
            if "429" not in str(e):
                break  # Non-quota error — don't retry
            time.sleep(1)
        except Exception as e:
            last_error = e
            break

    # Graceful degradation: return top memories as prior_decisions
    top_texts = [m["text"] for m in memories if m.get("text") and not m.get("error")][:5]
    err_str = str(last_error)[:120] if last_error else "unknown"
    return {
        "summary": (f"Context pre-loaded from {len(top_texts)} semantic memories. "
                    f"(Distillation unavailable: {err_str[:60]})"),
        "relevant_files": [],
        "prior_decisions": top_texts,
        "warnings": [],
        "key_facts": {
            "fleet_events": len(stdb.get("events", [])),
            "related_tasks_done": len(stdb.get("recent_tasks", [])),
        },
        "related_task_ids": [t["id"] for t in stdb.get("recent_tasks", [])],
        "_distilled": False,
        "_error": err_str,
    }


# ── Step 5: Write context ─────────────────────────────────────────────────────

def write_context(task_id: str, bundle: dict) -> str:
    """Write context.json to /tmp and optionally Minio."""
    path = f"{CONTEXT_DIR}/context-{task_id}.json"
    with open(path, "w") as f:
        json.dump(bundle, f, indent=2)

    # Optionally push to Minio
    minio_ep = os.getenv("MINIO_ENDPOINT", "")
    access_key = os.getenv("MINIO_ACCESS_KEY", "")
    secret_key = os.getenv("MINIO_SECRET_KEY", "")
    if minio_ep and access_key:
        try:
            _upload_minio(minio_ep, access_key, secret_key,
                          "fleet-context", f"{task_id}/context.json", path)
            bundle["_minio_url"] = f"{minio_ep}/fleet-context/{task_id}/context.json"
        except Exception as e:
            bundle["_minio_error"] = str(e)

    return path


def _upload_minio(endpoint: str, access_key: str, secret_key: str,
                  bucket: str, key: str, local_path: str):
    """Upload file to Minio using AWS SigV4 or presigned (simplified)."""
    import hashlib, hmac, datetime

    with open(local_path, "rb") as f:
        content = f.read()

    now = datetime.datetime.utcnow()
    date_str = now.strftime("%Y%m%d")
    datetime_str = now.strftime("%Y%m%dT%H%M%SZ")
    host = endpoint.replace("http://", "").replace("https://", "").split("/")[0]
    region = "us-east-1"
    service = "s3"

    content_hash = hashlib.sha256(content).hexdigest()
    canonical_headers = f"host:{host}\nx-amz-content-sha256:{content_hash}\nx-amz-date:{datetime_str}\n"
    signed_headers = "host;x-amz-content-sha256;x-amz-date"
    canonical_req = f"PUT\n/{bucket}/{key}\n\n{canonical_headers}\n{signed_headers}\n{content_hash}"
    string_to_sign = (f"AWS4-HMAC-SHA256\n{datetime_str}\n{date_str}/{region}/{service}/aws4_request\n"
                      + hashlib.sha256(canonical_req.encode()).hexdigest())

    def sign(key, msg):
        return hmac.new(key, msg.encode(), hashlib.sha256).digest()

    signing_key = sign(sign(sign(sign(f"AWS4{secret_key}".encode(), date_str), region), service), "aws4_request")
    signature = hmac.new(signing_key, string_to_sign.encode(), hashlib.sha256).hexdigest()
    auth = (f"AWS4-HMAC-SHA256 Credential={access_key}/{date_str}/{region}/{service}/aws4_request,"
            f" SignedHeaders={signed_headers}, Signature={signature}")

    req = urllib.request.Request(
        f"{endpoint}/{bucket}/{key}",
        data=content,
        headers={
            "Authorization": auth,
            "x-amz-date": datetime_str,
            "x-amz-content-sha256": content_hash,
            "Content-Type": "application/json",
        },
        method="PUT"
    )
    urllib.request.urlopen(req, timeout=10)


# ── Main ──────────────────────────────────────────────────────────────────────

def run(task_id: str, task_type: str, payload: str) -> dict:
    """
    Full CE pipeline. Returns context bundle dict.
    Writes to /tmp/context-{task_id}.json.
    """
    t0 = time.time()

    # 1. Semantic search
    memories = search_memories(f"{task_type}: {payload}")

    # 2. SpacetimeDB recent state
    stdb = get_stdb_context(task_type)

    # 3. Gemini distillation
    bundle = distill(payload, task_type, memories, stdb)

    # 4. Add metadata
    bundle["task_id"] = task_id
    bundle["task_type"] = task_type
    bundle["generated_at"] = int(t0)
    bundle["ttl_at"] = int(t0) + 3600
    bundle["memories_searched"] = len([m for m in memories if not m.get("error")])
    bundle["generation_ms"] = int((time.time() - t0) * 1000)

    # 5. Write
    path = write_context(task_id, bundle)
    bundle["_local_path"] = path

    return bundle


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: context_engineer.py <task_id> <task_type> <payload>")
        sys.exit(1)

    task_id   = sys.argv[1]
    task_type = sys.argv[2]
    payload   = " ".join(sys.argv[3:])

    # Load env from gemini config
    if not GEMINI_KEY and os.path.exists(os.path.expanduser("~/.config/gemini/config")):
        for line in open(os.path.expanduser("~/.config/gemini/config")):
            if "GEMINI_API_KEY" in line:
                os.environ["GEMINI_API_KEY"] = line.split("=", 1)[1].strip()
                break

    result = run(task_id, task_type, payload)
    print(json.dumps({
        "task_id": result["task_id"],
        "summary": result.get("summary", ""),
        "memories_searched": result.get("memories_searched", 0),
        "generation_ms": result.get("generation_ms", 0),
        "distilled": result.get("_distilled", False),
        "path": result.get("_local_path", ""),
        "prior_decisions": len(result.get("prior_decisions", [])),
        "warnings": len(result.get("warnings", [])),
    }, indent=2))
