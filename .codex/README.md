# LS-482 — visual delegation runtime

These are project-scoped definitions, not a global installation. Start the
companion task with its `--cwd` set to the ticket worktree. The lead reads
`AGENTS.md`; Codex discovers `.codex/agents/*.toml`. Each role file is its only
definition: there is no duplicate `codex/` tree or legacy role mapping.

The workflow is in AGENTS.md for this delivery. No new skill loader is assumed.
Pass an existing, revision-pinned brand skill path in the visual brief. Loading
a Markdown role description is not proof that a runtime agent was registered.

## Compatibility and authority

Authoring environment: Codex CLI 0.161.0; codex-cc-plugin/codex-companion bundle
1.0.6. Target reported by Claude: CLI 0.149.1; companion bundle 1.0.3.
Those versions are evidence context, not a tested minimum-version guarantee.

References:
- [Current subagents documentation](https://learn.chatgpt.com/docs/agent-configuration/subagents)
- [0.149.1 configuration schema](https://github.com/openai/codex/blob/rust-v0.149.1/codex-rs/core/config.schema.json)
- [0.149.1 role loader](https://github.com/openai/codex/blob/rust-v0.149.1/codex-rs/core/src/agent/role.rs)

The pinned schema supports the three `[agents]` fields used here. Standalone
roles specify name, description, developer_instructions and model. Reasoning
effort is inherited; if the target reports an unsupported combination, fail
visibly and have Claude select a supported setting rather than changing it
silently. The three-worker cap excludes the lead.

**Permissions are inherited.** In the 0.149.1 role application path, sandbox/MCP
settings are not among the applied role overrides. No `sandbox_mode` or MCP
settings are placed in these files to imply otherwise. Reviewer/verifier are
instructed not to write, but their prompts do not enforce a read-only security
boundary. The companion's parent permission policy and actual MCP tool surface
must be checked; filesystem sandboxing does not constrain external MCP writes.
This delivery neither loosens permission policy nor configures credentials.

Project configuration may be ignored for an untrusted worktree. Claude must
use the normal runtime trust flow with existing authorization and inspect the
effective project layer; do not auto-edit global trust or credentials. Higher
precedence overrides and inherited global agents/MCP must be visible in Q1's
sanitized evidence. Do not print an entire config or environment containing
tokens. The local command wrappers and Windows/macOS engines may differ.

The legacy Claude workflow is updated separately by LS-484. The issue #648
agreement defines the new lane, but this PR alone does not certify the existing
Claude hooks or CI enforce it. Until integration and Q1 pass, do not launch a
production visual ticket through this harness. WIP=1 remains until LS-483.

## Q1 acceptance probe — executed by Claude on the target host

Use an isolated disposable worktree containing exactly the candidate revision.
Do not test by changing the active development checkout or a shared Pen window.
Record the version of the actual Codex executable resolved by companion, the
companion bundle version, cwd, candidate commit, config/role hashes and effective
configuration source. If project config is ignored, stop and report that result.

Through the installed plugin's documented rescue/companion entrypoint, dispatch
this bounded read-only task with the isolated cwd (use its documented flags;
do not patch the installed companion to inject unsupported options):

> LS-482 Q1 probe only. Read AGENTS.md and the three project role definitions.
> Delegate one read-only acknowledgement task to each registered sprout_designer,
> sprout_visual_reviewer and sprout_delivery_verifier; use gpt-6.1-sol. Give each
> worker its named role and ask it to identify its assigned responsibility and
> return without touching design tools, files, Git or network services. Wait for
> all three results. Report missing roles/models/settings; never substitute a
> default agent or model. Do not design screens or run Q2.

Capture runtime events/transcript, not just the agents' self-reported model:

- Parent job/thread/cwd and candidate revision match the dispatch; AGENTS.md
  and this project's config were loaded, with overrides/source identified.
- Three distinct child thread IDs resolve the three named roles and model
  gpt-6.1-sol. Record actual reasoning effort and parent permissions/tool surface.
- Parent waits for all child completions; errors surface rather than producing
  a false success. No edits, active-document change or external mutation occurs.
- A bounded follow-up resumes the same task/thread; a fresh task is distinct.
  Correlate actual job/thread IDs rather than an unqualified 'last' session.

If a field cannot be observed in that runtime, mark it unverified and ask for
appropriate instrumentation; an acknowledgement string is not a substitute.
Use a missing-role/model request as a negative control only in the disposable
probe: it must not silently run another worker. Keep raw transcripts private;
post sanitized facts, IDs and hashes to #648, with no auth data/private URLs.

Static TOML/schema validation establishes file compatibility, not this runtime
acceptance. Claude owns Q1 and records its outcome before the handover.

## Q2 boundary — LS-483, not part of the Q1 probe

The known Windows authoring CLI was @pen.dev/cli 0.3.8. Its documented isolated
mode is `pen interactive --in <input.pen> --out <output.pen> --preview-output
<task-preview.png>` without `--app`. Verify the installed target version first.
Use disposable copies and a unique preview path; two engines must never write
the same file. Do not kill/switch the developer's active Pen instance.

Only Claude's coordinated LS-483 probe can establish Mac desktop/headless
coexistence and lock-screen layout reliability. Until then, claim neither
parallel-lane safety nor successful native accessibility behavior. Missing
Pencil/ImageGen/Sites capabilities are explicit limits, not reasons to reuse
unverified outputs. Publishing a pitch requires its own existing authorization.
