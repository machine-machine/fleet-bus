#!/usr/bin/env python3
"""
Pure-socket Redis client for fleet-bus agents.
No external dependencies — works in any Python 3.6+ environment.
"""
import socket
import time
import json


class RedisClient:
    def __init__(self, host="fleet-redis", port=6379, timeout=5):
        self.host = host
        self.port = port
        self.timeout = timeout
        self._sock = None
        self._buf = b""

    def connect(self):
        self._sock = socket.create_connection((self.host, self.port), self.timeout)
        self._sock.settimeout(self.timeout)
        self._buf = b""

    def close(self):
        if self._sock:
            try:
                self._sock.close()
            except Exception:
                pass
            self._sock = None

    def _send(self, *args):
        parts = ["*{}\r\n".format(len(args)).encode()]
        for a in args:
            b = a.encode() if isinstance(a, str) else str(a).encode()
            parts.append("${}\r\n".format(len(b)).encode() + b + b"\r\n")
        self._sock.sendall(b"".join(parts))

    def _recv_line(self):
        while b"\r\n" not in self._buf:
            chunk = self._sock.recv(4096)
            if not chunk:
                raise ConnectionError("Connection closed")
            self._buf += chunk
        line, self._buf = self._buf.split(b"\r\n", 1)
        return line

    def _read_response(self):
        line = self._recv_line()
        prefix = chr(line[0])
        data = line[1:].decode()
        if prefix == "+":
            return data
        elif prefix == "-":
            raise Exception("Redis error: " + data)
        elif prefix == ":":
            return int(data)
        elif prefix == "$":
            n = int(data)
            if n == -1:
                return None
            while len(self._buf) < n + 2:
                self._buf += self._sock.recv(4096)
            result = self._buf[:n].decode()
            self._buf = self._buf[n + 2:]
            return result
        elif prefix == "*":
            n = int(data)
            if n == -1:
                return None
            return [self._read_response() for _ in range(n)]
        raise Exception("Unknown prefix: " + prefix)

    def execute(self, *args):
        if not self._sock:
            self.connect()
        self._send(*args)
        return self._read_response()

    # ── High-level commands ───────────────────────────────────────────────────

    def ping(self):
        return self.execute("PING")

    def hset(self, key, mapping):
        args = ["HSET", key]
        for k, v in mapping.items():
            args += [str(k), str(v)]
        return self.execute(*args)

    def hgetall(self, key):
        result = self.execute("HGETALL", key)
        if not result:
            return {}
        return {result[i]: result[i+1] for i in range(0, len(result), 2)}

    def expire(self, key, seconds):
        return self.execute("EXPIRE", key, seconds)

    def sadd(self, key, *members):
        return self.execute("SADD", key, *members)

    def smembers(self, key):
        return set(self.execute("SMEMBERS", key) or [])

    def xadd(self, stream, fields, maxlen=None):
        args = ["XADD", stream]
        if maxlen:
            args += ["MAXLEN", "~", str(maxlen)]
        args.append("*")
        for k, v in fields.items():
            args += [str(k), str(v)]
        return self.execute(*args)

    def xrevrange(self, stream, start="+", stop="-", count=None):
        args = ["XREVRANGE", stream, start, stop]
        if count:
            args += ["COUNT", str(count)]
        return self.execute(*args) or []

    def lpush(self, key, *values):
        return self.execute("LPUSH", key, *values)

    def rpop(self, key):
        return self.execute("RPOP", key)

    def lrange(self, key, start, stop):
        return self.execute("LRANGE", key, start, stop) or []

    def setex(self, key, seconds, value):
        return self.execute("SETEX", key, seconds, value)

    def get(self, key):
        return self.execute("GET", key)

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, *args):
        self.close()


def heartbeat(host, port, agent_id, preset, agent_host, health_json, ttl=180):
    """Send a heartbeat to Redis. Returns 'ok' or raises."""
    with RedisClient(host, port) as r:
        now = int(time.time())
        r.hset("agent:{}".format(agent_id), {
            "id": agent_id, "preset": preset, "host": agent_host,
            "lastSeen": now, "health": health_json, "status": "alive",
        })
        r.expire("agent:{}".format(agent_id), ttl)
        r.sadd("agents", agent_id)
        r.xadd("events", {"agent": agent_id, "type": "heartbeat", "ts": now}, maxlen=1000)
    return "ok"


if __name__ == "__main__":
    import sys, os
    cmd = sys.argv[1] if len(sys.argv) > 1 else "heartbeat"
    host = os.environ.get("FLEET_REDIS_HOST", "fleet-redis")
    port = int(os.environ.get("FLEET_REDIS_PORT", "6379"))
    agent_id = os.environ.get("AGENT_ID", "unknown")
    preset = os.environ.get("AGENT_PRESET", "generalist")
    agent_host = os.environ.get("AGENT_HOST", "unknown")

    if cmd == "heartbeat":
        health = {}
        try:
            import psutil
            health["cpu"] = psutil.cpu_percent(interval=0.3)
            health["mem"] = psutil.virtual_memory().percent
        except ImportError:
            pass
        try:
            import urllib.request
            r = urllib.request.urlopen("http://localhost:18789/health", timeout=2)
            health["gateway"] = r.status == 200
        except Exception:
            health["gateway"] = False
        health_json = json.dumps(health)
        result = heartbeat(host, port, agent_id, preset, agent_host, health_json)
        print(result)

    elif cmd == "ping":
        with RedisClient(host, port) as r:
            print(r.ping())
