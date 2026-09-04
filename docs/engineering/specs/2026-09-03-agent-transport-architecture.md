# Agent transport and multi-replica architecture

**Date:** 2026-09-03
**Status:** Draft for debate (stage 1 of: debate → architecture plan → test app → implementation plan)
**Owner:** bjs
**Related docs:** upstream `docs/engineering/specs/2026-09-03-repository-operations-and-archive-history.md`
(commit `3d141ad9`, "the operations spec" below), upstream PR #888 (operations
phase 1, in review — see 2.5), upstream `docs/architecture/job-system.md`,
`docs/engineering/specs/2026-09-02-transport-architecture-handover.md` (superseded by this
document for everything except session history).

> **For agentic workers:** this is a discussion paper, not an implementation
> spec. Nothing in it authorizes touching borg-ui code. The mandated process
> is debate → architecture plan → test app that proves the architecture →
> implementation plan; borg-ui itself is not modified before the test app is
> green. Decisions already made are in Appendix B; do not re-open them, and
> do not re-open decisions in the operations spec's Appendix B either — that
> spec owns the job plane. If you believe a decision is wrong, stop and ask
> the owner.

---

## 1. Problem

Everything an agent does for the server is an `AgentJob` row plus
`agent_job_logs` rows, regardless of what kind of work it is. Three traffic
classes with incompatible needs ride one durable-job mechanism:

| Class | Examples | Semantics actually needed |
| --- | --- | --- |
| Interactive RPCs | browse, archive info/contents, extract, break-lock | caller waits, seconds latency, synchronous errors, no durability |
| Durable work | backups, check/prune/compact | admission control, restart survival, progress, cancel, reaper |
| Telemetry | logs, progress, heartbeats | fire-and-forget, loss-tolerant, high volume |

The database simultaneously serves as queue, RPC rendezvous, log sink,
progress channel, and audit trail. The code already admits the mismatch:
`_is_request_scoped_repository_job` exists solely to terminally fail
request-scoped jobs on agent reconnect; in-memory command futures exist in
`agent_connection_manager.py` but are process-local; waiting HTTP requests
poll the job row at 0.5 s; the agent job reaper is the crutch for lost
rendezvous. Measured cost: `agent_job_logs` is 88–91 % of every install's
database; `agent_jobs` ids reached ~68k on one production install within
weeks, dominated by the periodic stats refresh.

The forcing scenario is scale-out: one borg-ui instance responsible for the
local backups of ~1000 systems, run as multiple replicas in Kubernetes.
Replica-hostility today is pervasive: WS sessions, the artifact relay,
APScheduler singletons, and the `--workers 1` single-process deployment
constraint all assume one process. An earlier in-process attempt at direct
execution failed for exactly this reason — process-local state cannot work
across replicas.

The trigger was fork PR ioanalytica/borg-ui#38 (an Activity lane for failed
agent repository operations), closed unmerged on 2026-09-02: it would have
built more UI on top of the mismatch instead of removing it.

## 2. Relationship to the operations spec

The operations spec attacks the same root diagnosis from the job-plane side:
ad-hoc invisible derived-data computation, lock collisions between stats
refresh and backups, twelve job tables without a convention. Its non-goals
("No distributed queue. The runner is in-process." and "No changes to how
managed agents transport backups. `AgentJob` remains the transport record.")
carve out precisely this initiative's territory. This section is the
boundary agreement; everything later in this paper stays on our side of it.

### 2.1 Absorbed by the operations spec — we do not plan these

| Concern (previously ours) | Where the operations spec covers it |
| --- | --- |
| Admission control / "who owns the repository lane" | `operations` runner, lane rules (§7) |
| Coordination of derived-data work with backups | follow-up chains (§7.4), reconcile (§7.5) |
| Visibility of failed background repository operations (the #38 blind spot) | pipeline board red cards with retry (§10.1), repository status strip (§10.2) |
| Periodic stats-refresh flood (2 repository ops per repo per cycle) | persisted `archives` table + `archive_sync`/`stats` executors replacing the hourly scheduler (§6.4, §8) |
| Archive list as a live Borg call per view | DB-backed archive routes (§9.2) |
| Which server-side job classes get durable rows | everything through `enqueue()` gets an operation row; interactive folder browsing explicitly stays outside (§4 non-goals) |
| Job-plane consolidation (twelve tables, nine Activity queries) | phased migration onto `operations` (§13) |

### 2.2 Built on top of the operations spec — dependent work

| Item | Depends on | What we add |
| --- | --- | --- |
| Transport interface under the runner | operations phase 1 — **in review as upstream #888** | the executors' agent access goes through a `Transport` interface instead of the legacy AgentJob rendezvous; in #888 that access is already concentrated in one function (`list_archives_for_repository`, see 2.5), so the seam has a single concrete call-site |
| Transport/work-record split | operations phase 8 (`AgentJob.operation_id`) | `AgentJob` explicitly demoted to a transport record; the operation row is the work record; transient RPCs then need no `AgentJob` row at all |
| Agent `diff` command | operations spec §16 follow-up | protocol design for streaming large `borg diff --json-lines` output (up to `INDEX_HISTORY_MAX_ROWS` per archive) from agent to server — the first designed-for-purpose consumer of the telemetry lane; unblocks `history_index` for managed-agent repositories |
| Multi-replica runner | operations phase 9 (single runner is the only dispatcher) | making ONE runner replica-safe (lease/leader or broker-dispatched lanes) is tractable; making twelve scattered `asyncio.create_task` sites replica-safe was not |

The operations spec is a net win for this initiative even where it cements
the in-process assumption short-term: it builds the single choke point
(`enqueue()` → runner → executor → `BorgRouter`) that our phasing previously
had to create first.

### 2.3 Planned independently — the operations spec's explicit non-goals

| Item | Why it is ours alone |
| --- | --- |
| Transient RPC path for interactive agent operations (browse, archive info/contents, extract, break-lock) | "AgentJob remains the transport record" leaves these on the durable machinery; #888 confirms it in code — an agent-repo `archive_sync` produces an operation row *plus* an `AgentJob` row plus `agent_job_logs` plus the 0.5 s row polling |
| Telemetry transport (logs, progress, heartbeats) off the database | `agent_job_logs` volume is untouched by the operations spec |
| WS-session routing across replicas, presence | out of scope there ("no distributed queue") |
| The test app (N agents × M replicas harness) | proves transport properties the operations runner never claims |

### 2.4 Contributions to propose upstream early

Two items should go into the operations spec's process before its phase 1
and phase 2 code exists, so we never have to re-open a shipped design.
Non-goals are scope statements, not rejected alternatives, so proposing
these does not violate the spec's Appendix B etiquette — but both go through
Karan as owner, not through a fork-side fait accompli:

1. **Dispatch seam in the runner (phase 1).** Executors reach agents through
   one narrow interface (today: the connection manager call inside
   `BorgRouter`). Costs nothing in-process, keeps the door open for a
   broker-backed implementation without touching runner logic.
2. **Agent `diff` protocol design (before phase 2 ships agent-skip).** The
   operations spec marks agent repositories `history_state = skipped` until
   the protocol gains `diff`. We design that command against the streaming
   lane below so it does not get an ad-hoc `AgentJob`-shaped implementation
   later.

### 2.5 Phase 1 reality check — upstream #888 (2026-09-03)

Phase 1 was submitted as upstream PR #888 (`feat/operations-phase-1`,
+8779/−261 over 40 files, backend only, test-first) **the same day the spec
landed** — about 2.5 hours after the spec commit. It delivers the
`operations`/`archives`/`archive_changes` tables in one Alembic revision,
the runner with lanes/dependencies/recovery/cancellation, the `stats` and
`archive_sync` executors, the `/api/operations` router, the Activity union,
SSE events, and it deletes `stats_refresh_scheduler`.

Findings relevant to this paper, from the PR head (`92bb6f3e`):

- **The agent boundary is one function.** All agent access from the new
  executors goes through `list_archives_for_repository()` in
  `app/services/operations/executors/index.py`, whose agent branch is the
  legacy rendezvous verbatim: `queue_agent_repository_operation_job` →
  `dispatch_agent_job_best_effort` → `wait_for_agent_repository_operation_job`
  (the 0.5 s DB polling). The seam we wanted to request exists de facto —
  it just calls the wrong machinery. T2 replaces the body of that branch;
  nothing else in the runner needs to know.
- **Agent repositories are second-class in the index lane:** `run_stats`
  returns `agent_size_unsupported`, `fill_archive_info` skips agent repos
  entirely (no per-archive sizes in `archives`). Each gap is a future
  interactive-RPC or telemetry consumer for our transport, alongside the
  `diff` command.
- **The runner is per spec strictly process-local:** in-memory task handles,
  in-memory `cancel_requested` set, `asyncio.Event` wake, 5 s fallback poll,
  one instance per process. Exactly the T4 surface this paper predicted.

Consequences: the T0 window for the dispatch seam is the #888 review — after
merge, the seam proposal becomes a refactor PR against shipped code instead
of a review comment. And the operations phases arrive within hours, not
weeks; sequencing assumptions in §8 must not treat OS-Pn as slow-moving.

## 3. The central reframe

**The broker sits between the replicas, not between server and agent.**

Agents connect outbound only (WS session primary, REST polling fallback);
no server-side component can dial an agent. Any architecture keeps the
agent's WS connection as the last hop. The multi-replica problem is
therefore: *which replica holds agent X's socket right now?* — plus reply
routing back to the replica whose HTTP request is waiting.

- Commands: per-agent topics (`agent.<id>.cmd`), consumed by whichever
  replica holds the socket.
- Replies: correlation ids, routed to the requesting replica's reply inbox.
- Presence: broker-visible session ownership instead of `last_seen_at`
  columns.

The agent protocol itself does not change shape for this; the agent keeps
speaking WS to "the server".

## 4. Vocabulary

| Term | Meaning |
| --- | --- |
| Transport | The mechanism that moves a command to an agent and its result/output back. Not the job plane: the operations runner decides *what* runs; the transport decides *how it reaches the agent*. |
| Interactive RPC | A request-scoped agent call: an HTTP caller waits, errors surface synchronously, nothing survives a restart. |
| Durable dispatch | Delivery of a long-running operation (backup, check…) to an agent with restart survival and at-most-once admission. |
| Telemetry | Loss-tolerant, high-volume agent→server flow: log lines, progress, heartbeats. |
| Correlation id | Id linking an RPC reply to its waiting caller across replicas. |
| Presence | Knowledge of which replica currently owns an agent's live session. |
| Lane | Per-repository exclusivity slot — owned by the operations runner, consulted, never owned, by the transport. |

## 5. Requirements per traffic class

| Requirement | Interactive RPC | Durable dispatch | Telemetry |
| --- | --- | --- | --- |
| Latency | interactive (≤ seconds) | seconds acceptable | near-real-time nice-to-have |
| Durability | none — caller gone = request void | survives replica and agent restarts | loss-tolerant |
| Delivery | at-most-once | admission exactly-once; execution at-least-once only if idempotent (debate item Q2) | best effort |
| Error surface | synchronous, to the HTTP caller | operation row (`failed` + reason) | dropped or aggregated |
| DB rows | **zero** | one operation row (+ extension) | bounded, retained by policy — not per line in `agent_job_logs` |
| Volume | low, bursty (UI clicks) | low | high (1000 agents × log rate) |
| Replica concern | reply must reach the waiting replica | no double-dispatch when a replica dies | fan-in from all replicas to one sink/stream |
| Backpressure | timeout + synchronous error | queue depth visible to admission | drop oldest / sample |

## 6. Candidate designs

All candidates share the same shape: a `Transport` interface with
`rpc(agent, cmd, timeout)`, `dispatch(agent, operation)`, and a telemetry
sink/subscription, implemented twice.

**Broker-optional layering is non-negotiable for upstream.** The default
single-container/SQLite install must keep working with zero new
dependencies; a hard broker dependency will not be accepted. The interface
split alone already delivers value without any broker: transient ops stop
producing rows.

### 6.1 Design A — in-process transport (always exists, default)

The existing in-memory command futures
(`agent_connection_manager.resolve_command` / `reject_command`) formalized
behind the interface. Single process: the socket, the future, and the caller
are colocated, so RPC is a direct await; telemetry goes to the log-file sink
the operations runner already writes.

- Fixes: DB litter for interactive ops, the 0.5 s row polling, the
  reaper-as-rendezvous crutch, `_is_request_scoped_repository_job`.
- Does not fix: anything multi-replica. That is by design; A is the floor,
  not the goal.

### 6.2 Design B — Redis/Dragonfly-backed

Already deployed in both of our clusters and known to the chart; borg-ui
already has optional Redis for the archive-contents cache, so the
operational story ("you may already have this") is credible upstream.

- RPC: per-request reply channels (`RPUSH`/`BLPOP` or pub/sub) with
  correlation ids.
- Durable dispatch: Streams + consumer groups; pending-entry lists give
  crash-requeue.
- Telemetry: Streams with `MAXLEN` trimming.
- Weakest durability semantics of the three (acknowledged trade-off);
  presence via keyspace TTLs is workable but hand-rolled.

### 6.3 Design C — NATS

Request/reply is native (solves RPC + correlation for free), JetStream gives
durable consumer semantics for dispatch, subjects map cleanly to
`agent.<id>.cmd`. Single small binary, but a brand-new dependency with no
existing operational footprint in borg-ui installs or our clusters.

### 6.4 Decision method

B vs C is decided by the test app (section 7), not by taste: both get the
same harness runs, and the paper's acceptance criteria are the rubric.
AMQP/RabbitMQ is rejected without a test run (Appendix B).

## 7. Test app — the architecture proof

A standalone harness, green before borg-ui is touched, kept afterwards as a
permanent regression suite.

- N simulated agents: asyncio clients speaking the real agent WS protocol
  (enroll, session, command execution stubs with configurable latency).
- M server replicas running only the transport layer and a minimal
  operations-runner stub, behind the broker under test.
- Chaos switches: kill a WS mid-job, kill a replica, slow an agent to a
  crawl, restart the broker, partition one replica from the broker.

Acceptance criteria (to be finalized in debate):

1. No double-dispatch of a durable operation across replica failure.
2. Deterministic RPC timeout behavior: the waiting caller gets a
   synchronous error within `timeout + ε`, never a stuck request, never a
   ghost job.
3. Telemetry throughput: 1000 agents × target log rate sustained without
   any database involvement, with bounded memory.
4. Requeue correctness: an operation dispatched to a dead agent's topic is
   picked up exactly once when the agent reconnects to a *different*
   replica.
5. Presence accuracy: session ownership converges within a bounded window
   after replica death.

## 8. Phasing

Aligned with the operations spec's phases; "OS-Pn" refers to those.

| # | Phase | Depends on | Content |
| --- | --- | --- | --- |
| T0 | Upstream coordination | none — **urgent, OS-P1 is in review as #888** | Propose 2.4 items to Karan while the review window is open: the dispatch seam as a #888 review comment (one function, see 2.5), the agent `diff` protocol design before OS-P2 completes. Small, review-shaped contributions. |
| T1 | Architecture plan + test app | this paper debated | Finalize acceptance criteria, build the harness, run designs B and C against it. No borg-ui changes. |
| T2 | Transport interface + Design A | T1 green; OS-P1 (#888) merged | Extract the interface at the seam (`list_archives_for_repository`'s agent branch plus the interactive routes), move interactive agent ops onto the transient RPC path. Fixes DB litter single-replica. This touches the agent transport only — the operations spec's non-goal territory — so it does not collide with OS-P2…P8. |
| T3 | Broker-backed implementation | T2, test-app verdict | Second `Transport` implementation (B or C per T1 measurement), chart wiring, config. Off by default. |
| T4 | Multi-replica enablement | T3, OS-P9 (single runner is sole dispatcher) | Runner lease/dispatch across replicas, WS-session routing, scheduler singletons, artifact relay, drop `--workers 1`. Needs Karan's buy-in — this modifies his runner. |

House pattern for T2+ as with the borg2 work: prove on the fork, then
propose upstream.

## 9. Risks

- **Moving target — measured, not hypothetical.** Phase 1 went from spec
  commit to a submitted PR (#888) in ~2.5 hours; OS-P2…P9 will reshape
  dispatch while T1/T2 are in flight. The operations spec wins on the job
  plane; T2 rebases on it, never the reverse. Mitigation: T0's seam makes
  the contact surface one interface, and T0 must land inside the #888
  review window, not after.
- **Upstream acceptance.** Even broker-optional layering adds an
  abstraction Karan has to co-own. Mitigation: T0 first — small
  contributions establish the seam inside *his* spec's process; the
  transient-RPC value (no rows for clicks) is demonstrable on the fork.
- **REST-fallback agents** have no live session; a transient RPC path
  cannot serve them. Either interactive features require a live WS session,
  or the durable lane remains their fallback (debate item Q1).
- **Alembic churn.** OS phases add many upstream revisions; any fork-only
  revision we hold during T2+ re-triggers the two-head merge-revision
  protocol. Coordinate merge timing.
- **Telemetry retention.** Moving logs off `agent_job_logs` must not lose
  the Activity page's log viewer contract; the operations spec keeps
  per-operation `log_file_path`, which the telemetry sink can feed.

## 10. Open questions (debate items)

- **Q1 — REST-fallback agents:** keep the durable-job lane for them, or
  require a live WS session for interactive features?
- **Q2 — delivery semantics for durable dispatch:** exactly-once admission
  with at-least-once execution — what does borg actually tolerate on
  re-execution (create with same archive name, check, prune)?
- **Q3 — telemetry sink:** broker stream feeding the existing per-operation
  log file vs. direct-to-object-store vs. DB-with-retention only for the
  tail the UI shows live. What does the UI actually need in real time?
- **Q4 — agent durable rows:** the operations spec answers this for
  server-side work; for agents, does anything besides the operation row
  survive once `AgentJob` is a pure transport record — i.e. can
  `agent_jobs` shrink to in-flight rows only?
- **Q5 — involving Karan:** the "when" is decided by events — #888 being in
  review makes the seam a now-or-refactor-later choice (2.5), and prove-first
  is off the table for it. What remains open is the *form*: a review comment
  on #888 (cheapest, but injects our concern into his phase-1 review), or a
  small follow-up PR right after #888 merges (cleaner separation, but the
  seam then ships as a change to merged code). The `diff` protocol design
  keeps the original question: propose spec-side now, or with a fork-side
  prototype.

## 11. Working this document

| Stage | Status | Notes |
| --- | --- | --- |
| Debate (this paper) | in progress | audience: Benjamin first; T0 has a real-world deadline — the #888 review window (2.5) |
| Architecture plan | not started | after debate; decisions land in Appendix B |
| Test app | not started | acceptance criteria from §7 |
| Implementation plan | not started | per-phase plans, house pattern |

Update the table and Appendix B; do not rewrite history elsewhere in the
document. The upstream-facing subset (T0 items) becomes its own proposal
against `karanhudia/borg-ui`, not a copy of this paper.

---

## Appendix A. Current-state pointers

All paths in the `borg-ui` submodule (fork `ioanalytica/borg-ui`, upstream
`karanhudia/borg-ui`). Line-accurate as of upstream `d468ed4c`; the
operations spec's phases will move several of these — its Appendix A is the
authoritative inventory for the job plane.

| Site | Role |
| --- | --- |
| `app/services/agent_connection_manager.py` (`send_command(wait_for_result=…)`, `resolve_command`, `reject_command`) | process-local command futures — the seed of Design A |
| `app/api/agents.py` (`_is_request_scoped_repository_job`) | terminal-fails request-scoped jobs on reconnect; deleted by T2 |
| `app/services/repository_executor.py` (`wait_for_agent_repository_operation_job`) | 0.5 s DB polling rendezvous; deleted by T2; #888 adds a new caller (`executors/index.py`) |
| `app/services/operations/executors/index.py` (`list_archives_for_repository`, PR #888) | the one agent call-site of the phase-1 executors — the concrete seam for T0/T2 |
| `app/services/agent_job_reaper.py` | crutch for lost rendezvous; shrinks to durable-lane duty |
| `app/services/agent_artifact_relay.py` | single-process artifact relay; T4 territory |
| `app/core/borg_router.py` | agent-vs-server decision point; where the transport interface plugs in |
| `app/main.py` scheduler startup, `--workers 1` deployment constraint | replica-hostile singletons; T4 territory |

## Appendix B. Decisions and rejected alternatives

| Decision | Rejected alternative | Reason |
| --- | --- | --- |
| The operations spec owns the job plane; this initiative owns the agent transport plane | A competing unified design covering both | Same diagnosis, different layers; a second job-plane design would collide with an approved spec and re-litigate its Appendix B |
| Broker (if any) sits between replicas; the agent's outbound WS stays the last hop | Broker or queue protocol spoken by agents | Agents connect outbound only; changing the agent protocol multiplies the migration surface for zero routing gain |
| Broker-optional layering: in-process implementation is the permanent default | Hard broker dependency | Single-container/SQLite installs are upstream's core audience; would not be accepted, and Design A already fixes the DB-litter class alone |
| Test app must be green before borg-ui is touched, then kept as regression | Prototype directly inside borg-ui | Benjamin's mandated process (2026-09-02); transport claims are exactly the kind that only fail under chaos |
| AMQP/RabbitMQ rejected without a test run | Include it in the bake-off | Operationally heaviest by far; a non-starter for typical borg-ui installs, and both B and C cover the needed semantics |
| No more UI built on the durable-job machinery for request-scoped operations | Fork PR #38 (Activity lane for failed agent repository ops) | Closed unmerged 2026-09-02: it cements the mismatch; the operations spec's status strip covers the legitimate visibility need |
| Interactive RPCs produce zero DB rows | Slim per-request rows for audit | The caller's synchronous error IS the surface; audit belongs to durable operations (operations spec answer, adopted) |
