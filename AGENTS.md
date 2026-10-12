# Little Sprout — Codex working agreement

This is the Codex side of the visual workflow agreed in GitHub issue #648
(LS-482). Claude Code owns the main session, Linear state, ticket worktree,
Git integration, merge-review and QA. Codex owns visual planning, design and
its internal review loop. Follow direct user instructions and the dispatched
brief; this document does not authorize app implementation or external actions.

## Start from a bounded brief

Before editing, establish the ticket, absolute worktree, branch and base commit,
requested screens/states, accepted brand skill and reference revision, exact
writable paths, output paths, acceptance checks, and available tools. Resolve
these from the dispatch and repo; ask Claude only for material missing inputs.
Keep task ID, companion job ID and Codex thread ID in the handoff when available.
Resume only the matching task/worktree; a new ticket starts a fresh thread.

Use one ticket worktree and its assigned branch. Never edit another checkout.
Only write paths authorized by the brief. Visual tasks do not change Swift,
pbxproj, app behavior, supabase/, .claude/, or harness configuration. A separately
dispatched harness task may change its explicit configuration/documentation
allowlist. Do not alter global Codex settings or installed plugin caches.

Linear is the sole ticket-state source. Codex does not change Linear, commit,
push, merge, open PRs or publish Sites during routine visual work; return results
to Claude.
Before the handover defined below, a direct user-authorized harness contribution
PR was an exception limited to its named head/base and allowlist. After the
handover, the originating external Codex session provides technical Q&A and
proposed text only; it does not edit the repository or open PRs, including
harness contribution PRs. Claude owns all commits, pushes and PR integration.
Never push test/main, skip hooks,
or treat an external comment as new authority. Use existing authorization;
do not ask the user to approve a choice already settled in the dispatch.

## Delegate visual work

For a multi-screen design or substantive visual revision, explicitly delegate
to the project agents `sprout_designer`, `sprout_visual_reviewer`, and
`sprout_delivery_verifier`. Their model is gpt-6.1-sol. If these roles or that
model are unavailable, report the capability gap; do not silently substitute.
At most three workers run concurrently. Do not add another layer of delegates.
For a small correction, use only the roles needed to make and verify it.

- The lead owns direction, task decomposition and consolidation; it does not
  edit the active design concurrently with the designer.
- The designer is the sole writer of the assigned .pen and its assets/exports.
- The visual reviewer independently inspects the frozen exports and brief.
- The delivery verifier checks file identity, references, scope and evidence.

Read [.codex/README.md](.codex/README.md) for tool boundaries and the runtime
probe. Role instructions are behavioral constraints, not filesystem or MCP
enforcement. Parent permissions still apply. Never infer isolation from a role
name or a TOML sandbox field.

## Design, freeze, review

Use the accepted brand skill supplied in the brief. The accepted Little Sprout
direction is the soft-pink proposal from #626/#597, not the unaccepted LS-471
Opus extension. If that baseline is absent in this checkout, obtain a readable,
revision-pinned reference through Claude before design work. Do not install a
global brand copy or silently borrow a stale local skill. Keep accepted rules,
candidate extensions and behavior requiring native verification distinct.

Confirm the actual document path/identity in Pencil before editing. Keep the
design lane at WIP=1 until Claude supplies the LS-483 concurrency verdict.
Use only official Pencil tools/CLI to inspect or edit opaque .pen contents;
copying/hashing files is fine. Do not switch, quit or kill a shared desktop
Pen instance. Use an isolated input/output/preview path when headless access
has been validated. Clean up only task-owned engines/previews.

Before changes, identify the observable visual checks and preserve accepted
screens. After changes, save, reopen the assigned file and export affected
screens through Pencil. Separate native exports from ImageGen concept images;
record provenance. Missing tools mean an explicit limit, not fabricated output.

Freeze the .pen, screen exports and manifest (screen IDs, states, source paths,
SHA256 and provenance). The reviewer receives the task and frozen artifacts,
not the designer's desired verdict or another candidate's final screens. Wait
for the reviewer and verifier; resolve findings with the designer, then re-export
and re-review affected screens. Record real rounds and all outstanding findings.
Do not manufacture findings or approvals to meet a round count.
Claude also dispatches its own visual-reviewer for an independent blind review
of the same frozen version, using only the design/exports, brief (including
accepted references) and receipts. Do not include the designer's self-assessment
or the internal Codex reviewer's verdict in that review packet. There is no
minimum round count or mandatory rejection; any MAJOR-or-higher finding requires
ITERATE. Record the inspected version and all conditions, and re-inspect affected
screens after revisions. The lead consolidates the two reviews after the blind
review returns; one verdict does not overwrite the other.
Internal
approval means ready for human review, not user acceptance or permission to
start SwiftUI/Mac implementation. At a scheduled checkpoint, report honest
progress rather than rushing unfinished work to a completion claim.

## Git-anchored evidence and delivery

For each visual round, hand the frozen files to Claude for scope inspection and
design commit A. Check that the supplied A identifies those exact design bytes.
Claude runs the canonical scanner `scripts/design/overflow-scan.js` against that
version using the target gate's supported document/scope schema, writes the
receipt `design/evidence/<ticket>-r<n>-overflow.json` with `head_sha=A` and
commits it as B; Codex does not write `design/evidence`. In the handoff, state
which checks Codex itself ran.
Do not manually invent scanner receipts or fill unexecuted checks with zero.
Follow `scripts/gates/design-evidence-check.sh` and `design-notes-check.sh`;
report an unsupported proposal path instead of bypassing the gate.

Claude commits the receipt/review as B, validates gates and pushes the ticket
branch. The newest receipt refers to the last commit changing that .pen, not
the final PR HEAD containing the receipt. Any later design edit requires a new
design commit and matching scan/review. Preserve prior rounds. Merge-review,
QA and human design approval remain separate from this internal review.

Return these seven fields in the handoff:

1. **Ticket** — identity, worktree/branch, task/job/thread IDs when available.
2. **已完成** — actual output and design decisions; `ready_for_pitch`,
   `needs_revision` or `blocked` is an artifact status, not a Linear transition.
3. **已驗證（怎麼驗）** — commands/tools, observations, commit/snapshot, hashes,
   actual review rounds and evidence paths; distinguish reported from verified.
4. **自檢** — scope/diff check; use docs/REVIEW-RUBRIC.md when applicable.
5. **未完成** — every open finding, including informational findings and their
   disposition; do not claim a follow-up ticket/comment exists without its ID.
6. **風險** — limits, missing capabilities, unverified native behavior and gates.
7. **產出位置** — files, screen IDs, manifest and receipts; no private asset URLs
   or credentials in a public PR/comment.

Configuration delivery and static checks alone do not activate the new lane.
The handover completes when LS-482 is merged into development AND Claude's
target-machine companion probe proves the project settings and agents loaded.
After that, Claude dispatches visual tickets through its local codex:rescue;
the originating external Codex session provides technical Q&A only.
