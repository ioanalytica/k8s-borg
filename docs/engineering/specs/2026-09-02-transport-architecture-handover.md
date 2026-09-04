# Handover: borg-ui transport/job-plane architecture paper

Purpose of this document: enable a fresh working session to produce the
**architecture discussion paper** for rebuilding borg-ui's agent transport and
job plane. It captures the decision, the verified current-state facts with
code pointers, the candidate directions, and the agreed process — so the next
session can start writing instead of re-investigating.

## 1. The decision and its trigger

On 2026-09-02, fork PR ioanalytica/borg-ui#38 ("surface failed
repository-operation agent jobs" — an Activity lane for failed agent archive
listings etc.) was **closed unmerged** after Benjamin's review, despite being
CodeRabbit-green after two review rounds. His objection, which the code
corroborates: repository operations such as an archive listing are ordinary
request/response UI operations. Only the current architecture forces them
through the durable-job machinery — producing asynchronous error handling,
DB rows for fully transient actions, and finally UI to inspect the logs of
those contortions. Building more UI on that debt cements it.

Benjamin's direction (binding for this effort):

- Structural fix, not more symptom UI: request-scoped operations should become
  transient RPCs; he is thinking of a **message broker** for the multi-replica
  problem.
- Motivating scale scenario: one borg-ui instance responsible for the local
  backups of ~1000 systems; multiple borg-ui replicas in Kubernetes.
- Mandatory process: **debate → architecture plan → test app that proves the
  architecture → implementation plan**. borg-ui itself is not touched before
  the proof.

## 2. Verified current-state facts (with pointers)

All paths below are in the `borg-ui` submodule (fork `ioanalytica/borg-ui`,
upstream `karanhudia/borg-ui`).

**Three traffic classes ride one mechanism.** Everything an agent does is an
`AgentJob` row plus `agent_job_logs` rows:

| Class | Examples | Actual semantics needed |
|---|---|---|
| Interactive RPCs | browse, archive info/contents, extract, break-lock | caller waits, seconds latency, synchronous errors, no durability |
| Durable work | backups, check/prune/compact | admission control, restart survival, progress, cancel, reaper |
| Telemetry | logs, progress, heartbeats | fire-and-forget, loss-tolerant, high volume |

The database simultaneously serves as queue, RPC rendezvous, log sink,
progress channel, and audit trail.

**The code already admits the mismatch.**
- `app/api/agents.py`: `_is_request_scoped_repository_job` exists solely to
  terminally fail request-scoped jobs on agent reconnect ("no client is
  waiting for the result any more").
- `app/services/agent_connection_manager.py`: in-memory command futures
  (`resolve_command` / `reject_command`, `send_command(wait_for_result=...)`)
  exist — but are process-local.
- Waiting HTTP requests poll the DB row at 0.5 s
  (`app/services/repository_executor.py`, `wait_for_agent_repository_operation_job`).
- `app/services/agent_job_reaper.py` is the crutch for lost rendezvous.

**Measured cost.** `agent_job_logs` is 88–91 % of every install's DB (earlier
measurement); `agent_jobs` ids were ~68k on styxnet after weeks, dominated by
the periodic stats refresh (2 repository ops per repo per cycle:
`repository.list_archives` + `repository.rinfo`).

**Replica-hostility is pervasive, not local to transient ops.** WS sessions,
the artifact relay (`agent_artifact_relay`), APScheduler singletons, and the
deployment's `--workers 1` single-process constraint all assume one process.
An earlier in-process attempt at direct execution "failed permanently"
(Benjamin) — process-local state cannot work across replicas.

**Transport reality.** Agents connect **outbound only** (WS session primary;
REST polling as fallback). No server-side component can dial an agent. Any
architecture keeps the agent's WS as the last hop.

## 3. The central reframe for the paper

**The broker sits between the replicas, not between server and agent.** The
multi-replica problem is: *which replica holds agent X's socket right now?*
Broker topics per agent (`agent.<id>.cmd`), reply routing via correlation ids,
presence via the broker instead of `last_seen_at` columns. The agent link
itself is unchanged.

## 4. Candidate directions to evaluate

- **Redis/Dragonfly** — already deployed in both clusters and known to the
  chart. Streams + consumer groups for durable queues, reply channels for
  RPC. Weakest durability semantics of the three.
- **NATS** — request/reply native, JetStream for durability, single small
  binary; new dependency.
- **AMQP/RabbitMQ** — semantically most complete, operationally heaviest;
  likely a non-starter for borg-ui's typical single-container installs.

**Likely non-negotiable constraint for upstream: broker-optional layering.**
A transport interface (RPC + queue + events) with two implementations:
embedded in-process for the default single-container/SQLite install, and
broker-backed for scale-out. A hard broker dependency will not be accepted
upstream. The interface split alone already delivers value without a broker
(transient ops stop flooding the DB).

## 5. Test app (the architecture proof)

A harness that must be green before borg-ui is touched, kept afterwards as a
permanent regression:

- N simulated agents (asyncio clients speaking the real agent protocol)
  against M server replicas behind the broker.
- Chaos switches: kill WS mid-job, kill a replica, slow an agent, restart the
  broker.
- Acceptance criteria (to be finalized in the paper): no double-dispatch of
  durable jobs on replica failure; deterministic RPC timeout behavior;
  telemetry throughput at 1000 agents × target rate without DB involvement;
  requeue correctness.

## 6. Phasing sketch (to be detailed in the implementation plan)

1. Interface extraction at the existing choke point (`BorgRouter` is already
   the single decision point for agent-vs-server execution) + transient RPC
   path in-process — fixes the DB-litter problem even single-replica.
2. Broker-backed transport implementation.
3. Multi-replica enablement (schedulers, relays, WS-session routing).

## 6a. NEW (2026-09-03): Karan's own plan overlaps — read it first

Upstream commit `3d141ad9` added
`docs/engineering/specs/2026-09-03-repository-operations-and-archive-history.md`
(1236 lines, "Approved for implementation", owner karanhudia). It attacks a
large part of this initiative's problem space from the product side: it names
the ad-hoc, invisible, uncoordinated derived-data computation (stats refresh
colliding with backups on the Borg lock — exactly the failure class observed
on styxnet on 2026-09-02) and plans a repository-operations pipeline plus
persisted archive history. It references a `docs/architecture/job-system.md`.

**The architecture paper must start by reading that spec in full** and
position itself relative to it: which parts of the transient-RPC/broker
concern does Karan's pipeline already absorb, which remain (multi-replica
routing, transient interactive RPCs, telemetry transport), and whether the
right move is contributing to his spec rather than a parallel paper. His
implementation will also add Alembic revisions upstream — while our fork-only
revision `b9d2c5e7f1a4` (#871, still open) is applied in production, every new
upstream revision triggers the two-head merge-revision protocol (see memory
node `borgui-alembic-fork-revision-protocol`).

## 7. Open questions for the paper

- REST-fallback agents (no WS session): keep the durable-job lane for them,
  or require a live session for interactive features?
- Delivery semantics for backups: exactly-once admission vs. at-least-once
  with idempotence — what does borg tolerate?
- Log/progress transport at scale: broker stream vs. direct-to-object-store
  vs. keep-in-DB-with-retention; what does the UI actually need live?
- Audit/history: which job classes still get durable rows (backups yes;
  listings no) and where does the Activity page read from afterwards?
- How and when to involve Karan (pattern so far: prove on the fork, then
  propose upstream — as with the borg2 work).

## 8. What this initiative absorbs (parked items)

- Removal of the single-process constraint (`--workers 1`, 1 replica).
- "BorgRouter as the one choke point" north star (agent delegation).
- Archive-browse scaling (async/persisted browse).
- DB housekeeping pressure from `agent_jobs`/`agent_job_logs`.
- The blind spot #38 addressed: with transient RPCs, interactive failures are
  synchronous again; only the unattended stats refresh needs a signal — a
  repo-level "last stats refresh failed: <reason>" health field remains
  available as a small decoupled interim fix, independent of this effort.

## 9. Deliverable definition

The next session produces an **architecture discussion paper** (house
pattern: spec markdown on a fork branch, like the 2026-08 remote-SSH-source
spec) containing: problem statement and taxonomy (§2–3), requirements matrix
per traffic class, two to three candidate designs incl. the broker-optional
layering, the test-app specification with acceptance criteria, phasing, and
the open questions as debate items. Audience: Benjamin first; Karan later,
after fork-side validation.

## 10. Status ledger (as of 2026-09-02 evening)

- Fork PR #38: **closed unmerged** (rationale in closing comment); branch
  `fix/activity-repository-operation-lane` kept on the fork as reference —
  its CR-hardened pieces (shared lane predicate, SQL pagination, input
  validation, log-policy consistency) are reusable.
- `io/integration`: tip `4b754ccd` after the 2026-09-03 merge round
  (= upstream main + b23 stack + tz-fix; b22, notifications and the activity
  filter now arrive via main).
- Merged upstream 2026-09-03, patch-identity verified: #841 (borg2 b22!),
  #870 (agent-job notifications), #873 (activity status filter). Still open:
  #871 (archive-time timezone, follow-up issue #872) and the b23 follow-up
  submitted as #881.
- Related session memory nodes: `borgui-transport-architecture-initiative`
  (this effort), `borgui-single-process-constraint`,
  `borgui-agent-delegation-choke-point`, `borgui-db-housekeeping-needed`,
  `borgui-archive-browse-scaling`, `borgui-upstream-pr-roadmap`.
