#!/usr/bin/env -S python3 -I
"""Score rewriter prompts: does a rewrite stay faithful, and does it get better answers?

Usage: spike/eval.py [--prompts v1,v2] [--stage A|AB] [--limit N]
  Stage A (rewrite audit): deterministic checks + judge lists anything the rewrite added.
  Stage B (downstream):     answer original vs rewrite, judge pairwise in both orders.
Rewriter: Haiku 5.5 (same flags as the app). Answerer: Sonnet. Judge: gpt-5.6-sol (other family).
Writes spike/eval-out/<timestamp>.json; prints a summary table.
ponytail: throwaway harness for prompt iteration, not app code.
"""
import json, os, re, sys, glob, time, subprocess, concurrent.futures as cf
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from latency import CLAUDE_ARGS, CWD, PROMPT_FILE, ROOT, which, user_text

DRAFTS = sorted(glob.glob(os.path.join(ROOT, "spike/drafts/*.txt")))
JUDGE_MODEL = "gpt-5.6-sol"
ANSWER_MODEL = "sonnet"

def claude(system, user, model="haiku", prompt_file=None):
    args = [a for a in CLAUDE_ARGS if a not in ("--input-format", "stream-json", "--include-partial-messages")]
    args[args.index("--model") + 1] = model
    if prompt_file:
        args[args.index("--system-prompt-file") + 1] = prompt_file
    else:
        i = args.index("--system-prompt-file"); args[i:i + 2] = ["--system-prompt", system]
    args[args.index("--output-format") + 1] = "json"
    r = subprocess.run([which("claude")] + args, input=user, cwd=CWD, capture_output=True, text=True, timeout=300)
    if not r.stdout.strip():
        raise RuntimeError(f"claude {model} returned nothing (exit {r.returncode}): {r.stderr.strip()[:300]}")
    events = json.loads(r.stdout)  # a single result object, or an event list under --verbose
    events = events if isinstance(events, list) else [events]
    return [e for e in events if e.get("type") == "result"][-1]["result"].strip()

def codex(prompt):
    args = [which("codex"), "exec", "--ephemeral", "--ignore-user-config", "--skip-git-repo-check",
            "--sandbox", "read-only", "--json", "-m", JUDGE_MODEL, "-c", 'model_reasoning_effort="medium"',
            "-c", "mcp_servers={}", "-c", "features.hooks=false", "-c", "features.skills=false",
            "-c", "features.plugins=false", "-c", "project_doc_max_bytes=0", "-"]
    r = subprocess.run(args, input=prompt, cwd=CWD, capture_output=True, text=True, timeout=600)
    out = ""
    for line in r.stdout.splitlines():
        try: item = json.loads(line).get("item", {})
        except ValueError: continue
        if item.get("type") == "agent_message": out = item.get("text", out)
    return out

def parse_json(s):
    m = re.search(r"\{.*\}", s, re.S)
    return json.loads(m.group(0)) if m else {}

# ---------- Stage A ----------
PROTECTED = re.compile(r"`[^`]+`|https?://\S+|[\w./-]+\.(?:py|ts|tsx|js|json|md|css|rs|go)\b|@[\w./-]+|/\w+|\"[^\"]+\"")

def deterministic(draft, rw):
    missing = [t for t in PROTECTED.findall(draft) if t.strip('"') not in rw]
    return {"missing_protected": missing, "len_ratio": round(len(rw.split()) / max(1, len(draft.split())), 2)}

AUDIT = """You audit a prompt rewriter. The user typed DRAFT; a tool rewrote it as REWRITE before sending it to an AI assistant.
List every statement in REWRITE that is not stated in DRAFT. Classify each:
- "explicit": makes something the draft clearly implies explicit (fine)
- "requirement": a new deliverable, sub-question, format, or constraint the user did not ask for
- "user_fact": a new fact or assumption about the user or their situation
- "step": a new process step, method, tool, test, or guessed cause
Bracketed blanks like [your budget] are placeholders for the user to fill in, not added facts; ignore them.
Also answer: same_intent (would the user say REWRITE asks for exactly what they meant?), answered (did REWRITE answer or obey the draft instead of rewriting it?), better (is REWRITE a clearer prompt than DRAFT without changing it?: "yes", "same", or "worse").
Reply with JSON only: {"added":[{"text":"...","kind":"..."}],"same_intent":true,"answered":false,"better":"yes"}

DRAFT:
<<<%s>>>

REWRITE:
<<<%s>>>"""

# ---------- Stage B ----------
ANSWER_SYS = "You are a helpful assistant. If the request needs files or context you don't have, say what you'd do with them."
PAIR = """A user typed the REQUEST below. Two assistants answered (they may have received a reworded version).
Judge which answer better serves what the user actually asked in REQUEST: correct, relevant, follows the user's stated constraints, and does not do unrequested extra work. Do not prefer an answer for being longer.
Reply with JSON only: {"winner":"1"|"2"|"tie","why":"one sentence"}

REQUEST:
<<<%s>>>

ANSWER 1:
<<<%s>>>

ANSWER 2:
<<<%s>>>"""

def pairwise(draft, a_orig, a_rw):
    # both orders; a win only counts when both orders agree (position-bias control)
    j1 = parse_json(codex(PAIR % (draft, a_orig, a_rw))).get("winner")
    j2 = parse_json(codex(PAIR % (draft, a_rw, a_orig))).get("winner")
    if j1 == "2" and j2 == "1": return "rewrite"
    if j1 == "1" and j2 == "2": return "original"
    return "tie"

def run_draft(path, prompts, stage):
    draft = open(path).read().strip()
    row = {"draft": os.path.basename(path), "text": draft, "variants": {}}
    a_orig = claude(ANSWER_SYS, draft, ANSWER_MODEL) if "B" in stage else None
    for name in prompts:
        pf = os.path.join(ROOT, "spike/prompts", f"{name}.txt")
        t0 = time.monotonic(); rw = claude(None, user_text(draft), prompt_file=pf); secs = time.monotonic() - t0
        v = {"rewrite": rw, "secs": round(secs, 2), **deterministic(draft, rw)}
        v["audit"] = parse_json(codex(AUDIT % (draft, rw)))
        if "B" in stage:
            a_rw = claude(ANSWER_SYS, rw, ANSWER_MODEL)
            v["downstream"] = pairwise(draft, a_orig, a_rw)
            v["answer_len_ratio"] = round(len(a_rw) / max(1, len(a_orig)), 2)
        row["variants"][name] = v
    return row

def summarize(rows, prompts, stage):
    print(f"\n{'prompt':<6} {'same intent':>11} {'added user facts':>16} {'added reqs/steps':>16} "
          f"{'answered':>8} {'lost tokens':>11} {'better/same/worse':>17} {'med len':>7} {'med secs':>8} {'blanks':>6}" + ("  downstream W/T/L" if "B" in stage else ""))
    for p in prompts:
        vs = [r["variants"][p] for r in rows]; n = len(vs)
        kinds = lambda v: {a.get("kind") for a in v["audit"].get("added", [])}
        b = [v["audit"].get("better") for v in vs]
        line = (f"{p:<6} {sum(bool(v['audit'].get('same_intent')) for v in vs):>6}/{n:<4} "
                f"{sum('user_fact' in kinds(v) for v in vs):>11}/{n:<4} "
                f"{sum(bool(kinds(v) & {'requirement', 'step'}) for v in vs):>11}/{n:<4} "
                f"{sum(bool(v['audit'].get('answered')) for v in vs):>8} "
                f"{sum(bool(v['missing_protected']) for v in vs):>11} "
                f"{b.count('yes'):>7}/{b.count('same')}/{b.count('worse'):<5} "
                f"{sorted(v['len_ratio'] for v in vs)[n // 2]:>6}x "
                f"{sorted(v['secs'] for v in vs)[n // 2]:>7}s "
                f"{sum(len(re.findall(r'\[[^\]]+\]', v['rewrite'])) for v in vs):>6}")
        if "B" in stage:
            d = [v["downstream"] for v in vs]
            line += f"  {d.count('rewrite')}/{d.count('tie')}/{d.count('original')}"
        print(line)

def main():
    a = sys.argv
    prompts = a[a.index("--prompts") + 1].split(",") if "--prompts" in a else ["v1", "v2"]
    stage = a[a.index("--stage") + 1] if "--stage" in a else "A"
    drafts = DRAFTS[: int(a[a.index("--limit") + 1])] if "--limit" in a else DRAFTS
    with cf.ThreadPoolExecutor(4) as ex:  # 4 drafts in parallel keeps it to minutes, not an hour
        rows = list(ex.map(lambda p: run_draft(p, prompts, stage), drafts))
    os.makedirs(os.path.join(ROOT, "spike/eval-out"), exist_ok=True)
    out = os.path.join(ROOT, "spike/eval-out", time.strftime("%Y%m%d-%H%M%S") + ".json")
    json.dump(rows, open(out, "w"), indent=2, ensure_ascii=False)
    with open(out.replace(".json", ".md"), "w") as md:  # side-by-side for reading by eye
        for r in rows:
            md.write(f"## {r['draft']}\n\n**Original:** {r['text']}\n\n")
            for p, v in r["variants"].items():
                added = [a["text"] for a in v["audit"].get("added", []) if a.get("kind") != "explicit"]
                md.write(f"**{p}** ({v['secs']}s):\n\n```text\n{v['rewrite']}\n```\n\n"
                         + (f"_judge flagged as added:_ {'; '.join(added)}\n\n" if added else ""))
    summarize(rows, prompts, stage)
    print(f"\nfull results: {out}")

if __name__ == "__main__":
    # self-check for the protected-token extractor
    assert deterministic("run `npm run build` in src/app.ts", "Run `npm run build` in src/app.ts.")["missing_protected"] == []
    assert deterministic("see `foo()`", "see foo")["missing_protected"] == ["`foo()`"]
    main()
