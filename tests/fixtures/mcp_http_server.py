"""Disposable loopback fixture: no user services, real credentials or app effects."""
import base64
import hashlib
import http.server
import json
import queue
import sys
import threading
import urllib.parse
from pathlib import Path

streams = {}
authorizations = {}

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *_): pass
    @property
    def origin(self): return f"http://127.0.0.1:{self.server.server_port}"
    def response(self, status, value=None, headers=None):
        body = b"" if value is None else json.dumps(value).encode()
        self.send_response(status)
        if value is not None: self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for key, val in (headers or {}).items(): self.send_header(key, val)
        self.end_headers()
        if body: self.wfile.write(body)
    def sse(self):
        self.send_response(200); self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store"); self.end_headers()
    def event(self, value, event="message"):
        data = value if isinstance(value, str) else json.dumps(value)
        self.wfile.write(f"event: {event}\ndata: {data}\n\n".encode()); self.wfile.flush()
    def do_GET(self):
        url = urllib.parse.urlsplit(self.path); path = url.path
        if path in ("/legacy", "/fallback"):
            self.sse(); channel = queue.Queue(); key = str(id(channel)); streams[key] = channel
            self.event("/legacy/messages?session=" + key, "endpoint")
            try:
                while True: self.event(channel.get(timeout=60))
            except (BrokenPipeError, ConnectionResetError, queue.Empty): pass
            finally: streams.pop(key, None)
            return
        if path.startswith("/.well-known/oauth-protected-resource"):
            return self.response(200, {"resource": self.origin + "/oauth/mcp", "authorization_servers": [self.origin], "scopes_supported": ["tools"]})
        if path == "/.well-known/oauth-authorization-server":
            return self.response(200, {"issuer": self.origin, "authorization_endpoint": self.origin + "/authorize", "token_endpoint": self.origin + "/token",
                "registration_endpoint": self.origin + "/register", "code_challenge_methods_supported": ["S256"]})
        if path == "/authorize":
            query = dict(urllib.parse.parse_qsl(url.query)); authorizations["fixture-code"] = query
            callback = query["redirect_uri"] + "?" + urllib.parse.urlencode({"state": query["state"], "code": "fixture-code"})
            return self.response(302, headers={"Location": callback})
        if path == "/oauth/mcp": return self.response(401, headers={"WWW-Authenticate": f'Bearer resource_metadata="{self.origin}/.well-known/oauth-protected-resource/oauth/mcp", scope="tools"'})
        return self.response(405)
    def do_POST(self):
        url = urllib.parse.urlsplit(self.path); path = url.path
        size = int(self.headers.get("Content-Length", 0))
        if size > 1_000_000: return self.response(413)
        body = self.rfile.read(size)
        if path == "/register": return self.response(201, {"client_id": "fixture-public", "token_endpoint_auth_method": "none"})
        if path == "/token":
            form = dict(urllib.parse.parse_qsl(body.decode()))
            if form.get("resource") != self.origin + "/oauth/mcp": return self.response(400)
            if form.get("grant_type") == "authorization_code":
                query = authorizations.get(form.get("code"), {})
                challenge = base64.urlsafe_b64encode(hashlib.sha256(form.get("code_verifier", "").encode()).digest()).decode().rstrip("=")
                if query.get("code_challenge") != challenge or form.get("redirect_uri") != query.get("redirect_uri"): return self.response(400)
                return self.response(200, {"token_type": "Bearer", "access_token": "fixture-first", "refresh_token": "fixture-refresh", "expires_in": 1})
            if form.get("grant_type") == "refresh_token" and form.get("refresh_token") == "fixture-refresh":
                return self.response(200, {"token_type": "Bearer", "access_token": "fixture-renewed", "expires_in": 3600})
            return self.response(400)
        if path == "/fallback": return self.response(405)
        if path == "/redirect": return self.response(307, headers={"Location": self.origin + "/mcp"})
        if path == "/unauthorized": return self.response(401)
        if path == "/oauth/mcp" and self.headers.get("Authorization") != "Bearer fixture-renewed": return self.response(401)
        value = json.loads(body)
        if "id" not in value: return self.response(202)
        method, args = value["method"], value.get("params", {})
        if method != "initialize" and path not in ("/legacy/messages",) and (self.headers.get("MCP-Session-Id") != "fixture-session" or self.headers.get("MCP-Protocol-Version") != "2025-11-25"):
            return self.response(400)
        if method == "initialize": result = {"protocolVersion": "2025-11-25", "capabilities": {"tools": {"listChanged": True}}}
        elif method == "tools/list":
            if not args.get("cursor"): result = {"tools": [{"name": "echo", "description": "Fixture echo", "inputSchema": {"type": "object"}}], "nextCursor": "second"}
            else: result = {"tools": [{"name": "delayed", "inputSchema": {"type": "object"}}]}
        elif method == "tools/call":
            if args["name"] == "delayed": threading.Event().wait(5)
            result = {"content": [{"type": "text", "text": "fixture-ok"}], "structuredContent": args.get("arguments", {})}
        else: return self.response(400)
        reply = {"jsonrpc": "2.0", "id": value["id"], "result": result}
        if path == "/legacy/messages":
            streams[dict(urllib.parse.parse_qsl(url.query))["session"]].put(reply)
            return self.response(202)
        if path == "/stream":
            self.sse(); self.event(reply); self.close_connection = True; return
        return self.response(200, reply, {"MCP-Session-Id": "fixture-session"})

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
