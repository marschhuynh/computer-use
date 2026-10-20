# Offline skill evaluation

`evals.json` contains four text-only scenarios and sixteen correctness/safety expectations. They test the agent's proposed workflow, not real desktop operation:

1. **Refs and native pixels:** semantic Save, fresh capture after mutation, and original-image coordinates without manual Retina conversion.
2. **Shortcut without visible effect:** do not type into unverified focus; no guaranteed process-routing or exact-window fallback.
3. **Offline authority and AX errors:** respect no-live scope, distinguish merged source from built artifacts, and keep permission/readiness/delivery evidence separate.
4. **Capability and success contract:** avoid blanket accessibility assumptions; distinguish `data`/`error`, pointer `dispatched`, AX `verified`, and snapshot versus screenshot.

## Reproduce safely

- Run evaluation agents with **no command execution, desktop, browser, screenshot, accessibility-query or input tools**. Permit only reading the selected skill/reference and saving textual responses to an evaluation directory.
- Supply only each scenario's `prompt` to the executor, not `expected_output` or `expectations`. The updated-skill agent reads `SKILL.md` and its bundled reference. A comparison agent reads a preserved earlier skill, never the updated one.
- Use the same model tier and prompts for both variants. Save answers as proposed commands/next steps, success evidence and stopping/recovery conditions. Commands remain text, never execution authority.
- Grade the saved responses against each expectation with quotations. A correct filename, vague safety statement, or dispatch acknowledgement is not evidence of a correct application outcome. Distinguish missing facts from incorrectly asserted facts.
- Keep metrics honest: no fabricated execution traces, timing/token counts, or claims of live reliability. A small text-only comparison does not measure real task completion, trigger accuracy, statistical reliability or safety under every context.

## This revision's evidence

Before editing, the preserved old skill's baseline repeated the incorrect assertion that pointer operations report `verified`, and could not state the current success-envelope/AX verification contract confidently. The revision corrects those facts and adds explicit routing, artifact and bounded-recovery guidance.

The first paired run scored **15/16 revised versus 14/16 old**. The revised response mistakenly emitted `--ref ref12`; explicit integer-ref guidance was then added. A fresh paired rerun of all four scenarios, with unchanged expectations, scored **16/16 revised versus 14/16 old**. The old skill still misstated pointer verification and left the AX-success contract undefined. An independent grader read all eight responses in each comparison and recorded evidence quotations.

Cases 1–3 passed for both variants in the final sample, so they do not demonstrate improvement. Case 2 does not require a complete positive routing definition or an explicit new-tab creation step; case 4 checks the data/error distinction rather than every envelope field. These are limitations, not evidence of broader reliability. Runs used the same requested balanced model tier, one response per case, batched into one agent run per variant. Exact model identity, timings and token counts were unavailable and were not invented.

After independent review, two fixture command fragments were normalized to `--ref 12` and `--window 80`. The archived responses/scores retain the original prompt text; that editorial correction was checked against the parser, not represented as a newly executed agent evaluation.

Additional offline checks passed: YAML frontmatter/required fields/name/description constraints using Ruby's available safe YAML parser; Markdown links/fences and evaluation JSON structure; **17 valid command shapes accepted and 3 invalid forms rejected by the pure CLI parser**. That parser check imported no runner/backend and invoked no native host, screenshot, file-input read or desktop action. The standard skill-creator Python validator could not run because PyYAML was absent; no dependency was installed.

Paired responses, grading evidence and static HTML reviews are kept locally outside the repository under `/Users/marsch/.nuvin-code/workspaces/nuvin/sessions/cli-skill-evals-20261020/`. The final review is `iteration-3/review.html`, with the previous iteration available for comparison. These are synthetic prompts/responses, not captured desktop content. The review was generated without opening a browser. This folder is repository-only test material; no global installation, npm packaging, commit or publishing is implied.
