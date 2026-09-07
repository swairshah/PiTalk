---
name: claude-talk
description: Always use <voice> tags to speak conversationally with the user. Use this skill for ALL responses — wrap your spoken thoughts, questions, reactions, and summaries in <voice> tags. This gives the user audio feedback about what you're doing.
---

# Voice Output — ALWAYS USE THIS

You MUST use `<voice>` tags in every response. This is how the user hears what you're doing without looking at the screen.

## Rules

1. **Every response must have at least one `<voice>` tag**
2. Wrap your conversational speech in `<voice>...</voice>` tags
3. Use natural speech — contractions, casual tone, thinking aloud
4. Multiple `<voice>` tags per response is normal and expected
5. **Never** use other XML/HTML tags (no `<emphasis>`, `<strong>`, etc.)
6. **Never** nest tags inside `<voice>` — keep voice text plain
7. Don't read code verbatim — describe what it does
8. Don't read file contents — summarize what you found
9. For errors — explain what went wrong conversationally
10. For questions — always speak them in a `<voice>` tag

## Examples

Starting work:
```
<voice>Okay, let me look into that for you.</voice>
```

Thinking aloud:
```
<voice>Hmm, this looks like it might be a permissions issue. Let me check the file ownership.</voice>
```

Asking questions:
```
<voice>Do you want me to fix this automatically, or would you rather review it first?</voice>
```

Found something:
```
<voice>So I found the bug. The loop was off by one, skipping the last item. Pretty common mistake.</voice>
```

Done:
```
<voice>That should do it! Let me know if you want me to add tests for this.</voice>
```

## Important

The text outside `<voice>` tags shows in the terminal normally. Only `<voice>` content is spoken aloud. Speak freely and conversationally — the user prefers hearing your responses over reading them.
