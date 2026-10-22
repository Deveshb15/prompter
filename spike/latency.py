#!/usr/bin/env -S python3 -I
"""U1 latency spike: time claude -p and codex app-server/exec rewrites.

Usage: spike/latency.py [claude|codex|all] [--runs N] [--show]
Prints p50/p95 for time-to-first-text (ttft) and total, cold vs warm.
ponytail: throwaway measurement script; the app reimplements this in Swift (U4).
"""
import json, os, subprocess, sys, tempfile, threading, time, statistics, glob

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROMPT_FILE = os.path.join(ROOT, "Prompter/Resources/rewriter-prompt.txt")
DRAFTS = sorted(glob.glob(os.path.join(ROOT, "spike/drafts/*.txt")))
CWD = tempfile.mkdtemp(prefix="prompter-spike-")  # empty dir: no CLAUDE.md / AGENTS.md / .mcp.json
APP = "ChatGPT"

def user_text(draft):
    return f"<app>{APP}</app>\n<draft>\n{draft}\n</draft>"

def which(cli):
    return subprocess.run(["zsh", "-lc", f"command -v {cli}"], capture_output=True, text=True).stdout.strip().splitlines()[-1]

# ---------- Claude ----------
CLAUDE_ARGS = [
    "-p", "--model", "haiku", "--effort", "low",
    "--system-prompt-file", PROMPT_FILE,
    "--tools", "", "--disallowedTools", "mcp__*",
    "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
    "--setting-sources", "",  # swap for --safe-mode to compare (see docs/spike-results.md)
    "--no-session-persistence", "--permission-prompts", "none",
    "--input-format", "stream-json", "--output-format", "stream-json",
    "--verbose", "--include-partial-messages",
]

def claude_once(draft, warm_wait, show):
    p = subprocess.Popen([which("claude")] + CLAUDE_ARGS, cwd=CWD, stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
    if warm_wait:
        time.sleep(warm_wait)  # simulate a pre-warmed worker sitting idle before the hotkey
    t0 = time.monotonic(); ttft = None; out = ""; init = None
    msg = {"type": "user", "message": {"role": "user", "content": user_text(draft)}}
    p.stdin.write(json.dumps(msg) + "\n"); p.stdin.flush()
    for line in p.stdout:
        try: ev = json.loads(line)
        except ValueError: continue
        if ev.get("type") == "system" and ev.get("subtype") == "init":
            init = ev
        d = ev.get("event", {}).get("delta", {}) if ev.get("type") == "stream_event" else {}
        if d.get("type") == "text_delta" and ttft is None:
            ttft = time.monotonic() - t0
        if ev.get("type") == "result":
            out = ev.get("result", ""); break
    total = time.monotonic() - t0
    p.kill(); p.wait()
    if show and init:
        print(f"  init: tools={init.get('tools')} mcp={init.get('mcp_servers')} model={init.get('model')}")
    return ttft, total, out

# ---------- Codex (app-server, warm) ----------
# Keep the user's MCP servers, hooks and skills out of the rewrite (they add startup time and context).
CODEX_ISOLATE = ["-c", "mcp_servers={}", "-c", "features.hooks=false", "-c", "features.skills=false", "-c", "features.plugins=false", "-c", "features.apps=false",
                 "-c", "project_doc_max_bytes=0", "-c", 'web_search="disabled"']

class CodexServer:
    """Unverified protocol field names: this spike exists to confirm them (run with --show)."""
    def __init__(self):
        self.p = subprocess.Popen([which("codex"), "app-server", *CODEX_ISOLATE], cwd=CWD, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.id = 0
        self.rpc("initialize", {"clientInfo": {"name": "prompter-spike", "version": "0"}})
        self.send({"method": "initialized"})

    def send(self, obj):
        self.p.stdin.write(json.dumps(obj) + "\n"); self.p.stdin.flush()

    def rpc(self, method, params):
        self.id += 1; rid = self.id
        self.send({"id": rid, "method": method, "params": params})
        for line in self.p.stdout:
            msg = json.loads(line)
            if msg.get("id") == rid:
                if "error" in msg: raise RuntimeError(f"{method}: {msg['error']}")
                return msg.get("result", {})

    def rewrite(self, draft, show):
        instructions = open(PROMPT_FILE).read()
        t0 = time.monotonic(); ttft = None; out = ""
        th = self.rpc("thread/start", {"model": "gpt-5.6-luna", "cwd": CWD, "approvalPolicy": "never",
                                       "sandbox": "read-only", "baseInstructions": instructions, "ephemeral": True})
        tid = th.get("thread", {}).get("id")
        self.id += 1
        self.send({"id": self.id, "method": "turn/start",
                   "params": {"threadId": tid, "effort": "low",
                              "input": [{"type": "text", "text": user_text(draft)}]}})
        for line in self.p.stdout:
            msg = json.loads(line); m = msg.get("method", "")
            if show and m in ("error", "warning"): print("  <-", m, json.dumps(msg.get("params"))[:400])
            if "error" in msg: raise RuntimeError(msg["error"])
            if m == "item/agentMessage/delta":
                if ttft is None: ttft = time.monotonic() - t0
                out += msg["params"].get("delta", "")
            if m == "turn/completed": break
        return ttft, time.monotonic() - t0, out

    def close(self):
        self.p.kill(); self.p.wait()

# ---------- Codex (exec, cold) ----------
def codex_exec_once(draft, show):
    instructions = open(PROMPT_FILE).read()
    args = [which("codex"), "exec", "--ephemeral", "--ignore-user-config", "--skip-git-repo-check",
            "--sandbox", "read-only", "--json", "-m", "gpt-5.6-luna", *CODEX_ISOLATE,
            "-c", 'model_reasoning_effort="low"', "-c", "project_doc_max_bytes=0",
            "-c", 'web_search="disabled"', "-c", f"developer_instructions={json.dumps(instructions)}", "-"]
    t0 = time.monotonic(); ttft = None; out = ""
    p = subprocess.Popen(args, cwd=CWD, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True)
    p.stdin.write(user_text(draft)); p.stdin.close()
    for line in p.stdout:
        try: ev = json.loads(line)
        except ValueError: continue
        item = ev.get("item", {})
        if item.get("type") == "agent_message":
            ttft = ttft or time.monotonic() - t0; out = item.get("text", out)
    p.wait()
    return ttft, time.monotonic() - t0, out

# ---------- harness ----------
def report(label, rows):
    tt = [r[0] for r in rows if r[0] is not None]; tot = [r[1] for r in rows]
    pct = lambda xs, q: sorted(xs)[min(len(xs) - 1, int(q * len(xs)))] if xs else float("nan")
    print(f"{label:<22} n={len(rows):<3} ttft p50={pct(tt,.5):.2f}s p95={pct(tt,.95):.2f}s  "
          f"total p50={pct(tot,.5):.2f}s p95={pct(tot,.95):.2f}s")

def main():
    which_cli = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else "all"
    runs = int(sys.argv[sys.argv.index("--runs") + 1]) if "--runs" in sys.argv else 3
    show = "--show" in sys.argv
    drafts = [open(f).read().strip() for f in DRAFTS]
    assert drafts, "no drafts in spike/drafts"

    def run(label, fn):
        rows = []
        for _ in range(runs):
            for name, d in zip(DRAFTS, drafts):
                r = fn(d); rows.append(r)
                if show: print(f"--- {label} {os.path.basename(name)} ---\n{r[2]}\n")
        report(label, rows)

    if which_cli in ("claude", "all"):
        run("claude cold", lambda d: claude_once(d, 0, show))
        run("claude warm (3s idle)", lambda d: claude_once(d, 3, show))
    if which_cli in ("codex", "all"):
        run("codex exec cold", lambda d: codex_exec_once(d, show))
        srv = CodexServer()
        try: run("codex app-server warm", lambda d: srv.rewrite(d, show))
        finally: srv.close()

if __name__ == "__main__":
    main()
