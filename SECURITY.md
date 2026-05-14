# Security

## Important Disclaimer

**atelier-cc runs autonomous multi-stage pipelines inside Claude Code.** Each stage dispatches a sub-agent that reads, writes, edits files, runs shell commands, and makes git commits in your workspace — typically across many turns without intermediate human review.

The plugin itself does not bypass Claude Code's permission system. However, autonomous operation is impractical with default per-call permission prompts, so most users will run atelier-cc with broad permission allowlists, `--dangerously-skip-permissions`, or equivalent. **Treat any autonomous run as if every tool call had already been approved.**

Agents run with the same filesystem, network, and credential access as your Claude Code process. There is no built-in sandbox, action filter, or rollback mechanism beyond ordinary git history.

## Recommendations

- Run atelier-cc inside a **container**, **VM**, **disposable worktree**, or **isolated machine account** to limit blast radius. The plugin supports git-worktree-based isolation per pipeline — prefer worktree mode when classifying a new pipeline.
- **Never** run on machines with production credentials, SSH keys to production servers, or sensitive data accessible from the workspace.
- Review pipeline artifacts (specs, plans, code, tests) before merging the worktree branch back into your main branch — autonomous agents will produce confident-sounding output that may be wrong.
- Inspect `.atelier/pipelines/<id>/progress.md` and the per-stage artifacts to audit what each agent actually did.
- Configure Claude Code's permission allowlist as narrowly as your workflow tolerates. Even autonomous pipelines do not require unrestricted network or arbitrary system command access for most coding tasks.
- Be cautious with prompts sourced from untrusted issues, web pages, or third-party documents — they can contain prompt-injection payloads that an autonomous agent will act on without confirmation.

## Reporting Vulnerabilities

If you discover a security issue, please open a GitHub issue or email the maintainer directly.
