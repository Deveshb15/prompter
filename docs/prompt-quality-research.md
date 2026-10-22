# What makes a rewrite "better": research synthesis (2026-10-22)

This synthesizes two independent research passes: Claude Opus 5.5 (vendor guidance and papers) and GPT-6.1-Sol (GitHub enhancer prompts and practitioner reports). They reached the same conclusion from different directions.

## The core finding

**A rewriter's biggest risk is inventing things, not leaving prompts vague.** Current models (Claude 5.x, GPT-5.5+, Gemini 3) follow instructions literally. Anything the rewriter adds, such as "I'm a beginner" or "suggest practice projects", becomes a real requirement the answering model carries out.

- *What Prompts Don't Say* (Findings ACL 2026): stating 19 requirements instead of 1 dropped accuracy from 98.7% to 79.7–85%. Models already guess about 70% of format requirements unprompted.
- BPO (ACL 2024) and Sarkar et al. (2025): rewriting helps on average, but less for stronger models, more for information-seeking requests, and less for creative ones. Weak rewriters can cause net harm.
- Much of the reported gain likely comes from LLM judges preferring longer answers (Dubois et al., COLM 2024).
- Real enhancer prompts that bloat (bolt.diy, `linshenkx/prompt-optimizer` "professional", a community Raycast extension) share one pattern: **"preserve intent" + "add missing context" + "don't ask questions"**. When context is missing, those instructions force the model to invent it.

## What helps (keep or add)

| Dimension | Evidence | Applies to |
|---|---|---|
| Never invent facts, requirements, steps, or formats | Strong | All |
| Ask first, clean grammar, define vague references using the draft only | Strong (all 3 vendors; ProTeGi) | All |
| Make context the draft already holds explicit (error text, files, symptom) | Strong | Coding ≫ chat |
| Goal / current behavior / must-not-change / done-when | Strong for agents (Codex, Claude Code best practices) | Coding |
| Keep the user's constraints exactly: don't broaden or tighten | Strong (literal following) | All |
| One clarify line only when ambiguity changes the result | Mixed: +74% for coding agents (Ambig-SWE), but noise for chat | Mostly coding |
| Preserve follow-ups ("now make it shorter") as-is | Practice (cursor-prompt-enhancer, Augment complaints) | Chat |
| "Already good" returns unchanged | Strong (gains shrink on strong models) | All |

## What to strip, never add

Personas ("You are an expert…"): no accuracy gain (Zheng 2024, Wharton PSR4) and can override instructions in Gemini. "Think step by step": marginal gain at 20–80% time cost on reasoning models (PSR2). ALL-CAPS / "CRITICAL": overtriggers on Claude 4+. Threats and tips: no effect (PSR3). Invented output formats, examples, test commands, root causes.

## Product implications

1. **The default mode is "Polish":** faithful clarification. It should often look like a light edit, and that counts as success.
2. **"Expand" is a separate, explicit mode** for when the user *wants* suggestions added (learning paths, creative image detail). Never do it silently. Both reports recommend this split.
3. **App awareness is a hint only.** A terminal could be Claude Code or a plain shell. Use it to protect syntax (`/commands`, `@mentions`), not to infer the project.
4. **Code-level guards, no extra model call:** protected tokens (code, paths, URLs, @mentions, /commands) must survive the rewrite, or the original is kept. Track the length ratio.
5. **Show what was added:** a diff or highlight of new sentences, plus one-key undo.
6. **Learn from undo and edits, not from acceptance.** Never store per-draft details (stack, skill level) as facts about the user.

## How we measure it (`spike/eval.py`)

- **Stage A, the rewrite audit:** deterministic protected-token and length checks, plus a different-family judge (gpt-5.6-sol). The judge labels every added statement as explicit, new requirement, new user fact, or new step, and rates same-intent and better/same/worse.
- **Stage B, downstream:** Sonnet answers the original draft and the rewrite. The judge picks the better answer **relative to the original draft only**, run in both orders; it counts as a win only when both orders agree, otherwise a tie. The answer length ratio is logged to spot length bias.
- 26 drafts across chat, advice, coding (bug, feature, refactor, vague, tests), writing, data, image, follow-ups, already-good prompts, injections, uncertainty, slash/@ syntax, non-English, and a long messy draft.
- With 26 items, about 18+ wins out of the non-tie comparisons is needed before a downstream claim is meaningful. Smaller margins are directional only.

## Sources

Full source lists are in the two research reports; the key ones:

- Anthropic: [prompting best practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices), [Haiku 5.5](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-haiku-5-5), [Claude Code best practices](https://code.claude.com/docs/en/best-practices)
- OpenAI: [GPT-5.5 guide](https://developers.openai.com/api/docs/guides/latest-model/gpt-5.5), [Codex best practices](https://developers.openai.com/codex/learn/best-practices)
- Google: [prompt design strategies](https://ai.google.dev/gemini-api/docs/prompting-strategies)
- Papers:
  - [What Prompts Don't Say](https://arxiv.org/html/2505.13360v2)
  - [BPO](https://arxiv.org/abs/2311.04155)
  - [Sarkar et al. 2025](https://arxiv.org/abs/2503.16789)
  - [Ambig-SWE](https://arxiv.org/abs/2502.13069)
  - [IFScale](https://arxiv.org/abs/2507.11538)
  - [Wharton PSR2](https://arxiv.org/abs/2506.07142) / [PSR3](https://arxiv.org/abs/2508.00614) / [PSR4](https://arxiv.org/abs/2512.05858)
  - [Length-controlled AlpacaEval](https://arxiv.org/abs/2404.04475)
  - [When Generic Prompt Improvements Hurt](https://arxiv.org/html/2601.22025v2)
- Enhancer prompts read:
  - [bolt.diy enhancer](https://github.com/stackblitz-labs/bolt.diy/blob/b285272f91cc5445ea7d8a0df4be3ff5b2c4b6e6/app/routes/api.enhancer.ts)
  - [prompt-optimizer templates](https://github.com/linshenkx/prompt-optimizer/tree/a201f47d2b17d6cf6a9347f336691b00c98720a1/packages/core/src/services/template/default-templates/user-optimize)
  - [cursor-prompt-enhancer](https://github.com/ajrcre/cursor-prompt-enhancer/blob/b8aa207884825be9bbced2eec5b5d134aff7c920/hooks/prompt-enhancer.mjs)
  - [OpenAI Generate metaprompt](https://developers.openai.com/api/docs/guides/prompt-generation)
  - [Anthropic metaprompt notebook](https://github.com/anthropics/claude-cookbooks/blob/470dd66397222de71c1a9b8c7fb672edb0ca23af/misc/metaprompt.ipynb)

## Eval results (2026-10-22, 26 drafts, Haiku 5.5 rewriter, gpt-5.6-sol judge)

| Prompt | Same intent | Invented user facts | Added reqs/steps | Answered instead of rewriting | Typical length | Typical time |
|---|---|---|---|---|---|---|
| v1 (original) | 4/26 | 2/26 | 22/26 | 1 | 4.6× | — |
| v2 Polish (final) | 26/26 | 0/26 | 0/26 | 1 (edited a quote; caught by protected-token guard) | 1.0× | 3.3 s |
| Expand (final) | n/a: adds by design | 5/26, mostly minor | by design | 1 (refused the jailbreak draft) | 6.6× | 4.3 s |

- Downstream (Sonnet answers, judged in both orders): v1 lost to the original draft 14 vs 8. v2 came out 6/9/11 (wins/ties/losses against the original), which is within noise because its rewrites are nearly the original text. **Rewording alone does not improve a strong model's answers.**
- **Key finding:** `claude -p` adds hidden context blocks (account email and an Environment section) to every call. `--bare` would skip them, but it doesn't work with subscription logins. Haiku treated the blocks as an injection and refused 4–8 of 26 Expand drafts until both prompts named the blocks as routine. Keep that line in both prompts.
- Read the outputs side by side in `docs/rewrite-samples.md`.
