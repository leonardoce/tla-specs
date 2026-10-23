# Stall Prevention for CloudNativePG During Node Group Upgrades

**Status:** design proposal  
**Audience:** CloudNativePG maintainers and reviewers  
**Source model:** `StallPrevention.tla`, composed in `CnpgUpgrade.tla`

---

## 1. Decision summary

The deadlock has two possible remedies. They are alternatives, not two
optimizations of one algorithm:

| Remedy | What it does | Switchovers | Replica margin | Default |
|---|---|---|---|---|
| **Deletion** | Removes one replica so CNPG rebuilds it on an uncordoned node; a normal switchover then moves the primary there | one | temporarily `instances - 2` replicas | **yes**, when safe |
| **Promotion** | Promotes a healthy replica that is still on a cordoned node, even though CNPG would normally refuse to switch over to it | two or more | `instances - 1` replicas until the old primary is drained; then `instances - 2` until the replacement is ready | opt-in |

The proposed design is:

1. **Deletion is the default**, because it produces a single switchover and does
   not repeatedly interrupt writes.
2. **Promotion is an explicit opt-in**, for clusters that cannot give up a
   replica before the switchover (for example two-instance clusters with
   synchronous replication).
3. The signal is a **validating admission webhook on the legacy `pods/eviction`
   subresource**. It does not depend on the declarative eviction API
   (`EvictionRequest` / `Eviction`, KEP-4563).
4. The webhook **denies the primary eviction with a retryable status** and
   records a request. The operator performs the remedy asynchronously and
   idempotently. The webhook never waits for a switchover inside the admission
   call.
5. CNPG's existing switchover machinery remains the only way the primary is
   moved. The feature adds a signal and a remedy; it does not introduce a second
   failover mechanism.

---

## 2. The problem

### 2.1 The deadlock

Consider a Kubernetes node group upgrade that follows *surge, then drain*:

1. All old nodes are cordoned at the beginning of the operation.
2. Replacement nodes are added and remain uncordoned.
3. A drainer (`kubectl drain`, a cloud node group controller, a maintenance
   operator, etc.) starts evicting Pods from the old nodes using the eviction
   API.

CloudNativePG spreads its instances across nodes, so each old node hosts one
instance. The primary is on one of those old nodes.

When the drainer reaches the primary:

1. An eviction request is created for the primary Pod.
2. The CNPG **primary PodDisruptionBudget** selects the primary and has
   `minAvailable: 1`. With exactly one healthy primary, `disruptionsAllowed` is
   zero, so the eviction is rejected with `429 Too Many Requests`.
3. The CNPG operator notices that the primary is on an unschedulable node and
   tries to switch over. Its normal candidate selection deliberately skips every
   replica whose node is unschedulable.
4. In this scenario every replica is on a cordoned old node, so there is no
   candidate. No switchover happens.
5. The primary stays primary, the primary PDB keeps rejecting the eviction, and
   the drain never completes.

That is the stall. It is not a PDB defect: the PDB is correctly protecting the
only primary. The missing capability is a **safe, controlled way to move the
primary when no replica is on a schedulable node**.

If the drainer happens to evict a replica first, CNPG can rebuild that replica
on a new node and the deadlock may resolve by itself. The pathological case is
primary-first eviction, or all CNPG nodes being cordoned before any replacement
instance becomes ready. The solution must handle both orders.

### 2.2 Why the obvious shortcuts are wrong

| Shortcut | Why it is not acceptable |
|---|---|
| Disable the PDBs | Removes the only protection against evicting the primary. It converts a stall into an unplanned failover and possible data loss. |
| Remove the "candidate node must be schedulable" check unconditionally | CNPG would switch over to a node that is about to be drained, causing unnecessary and repeated switchovers even during ordinary cordons. |
| Delete or force-evict the primary | Destroys the data-safety guarantee the PDB is there to provide. |
| Wait for the node to become schedulable again | That defeats the purpose of the upgrade; the old node is going away. |

### 2.3 What the model establishes

`CnpgUpgrade.tla` composes a node group, CNPG Pods, a scheduler, and the two
remedies. TLC checks deletion-only, promotion-only, and both remedies together,
and in all three configurations the liveness property `AlwaysFinishUpgrade`
holds.

The model is deliberately small. It abstracts away PostgreSQL health,
synchronous replication, storage and PVC node affinity, PDB behavior, the
eviction admission path, and asynchronous failures. It proves that the deadlock
is breakable with a small, local action. It does **not** prove that the action is
safe in PostgreSQL terms.

The implementation must therefore be more conservative than the model: the
model is evidence that the design can finish, not a specification of when a
real switchover is safe.

---

## 3. Proposed solution

### 3.1 Overview

The solution separates the **signal** from the **actuation**:

```text
drainer
  │ evicts primary Pod
  ▼
kube-apiserver
  │ admission chain
  ▼
CNPG eviction webhook
  │ meaningful primary eviction?
  ├─ no  ──► allow; PDB and normal CNPG behavior apply
  └─ yes ──► record request, deny with 429
                 │
                 ▼
             CNPG operator
                 │ performs one guarded remedy
                 ▼
             existing CNPG switchover / instance management
                 │
                 ▼
             drainer retries and the eviction succeeds
```

- **Signal layer:** the admission webhook. It must be fast, must not call the
  instance manager, and must not wait for a switchover.
- **Actuation layer:** the operator. It owns the decision and the mutation, with
  the same idempotency and retry behavior as the rest of CNPG.

The webhook is only the trigger. It never deletes a Pod, promotes a replica, or
waits for PostgreSQL.

### 3.2 The signal: an eviction webhook

#### Why the eviction attempt, not the cordon

`policy/v1 Eviction` is a virtual subresource. It is not persisted as a
watchable object. Admission is the portable way to observe an eviction attempt
on current Kubernetes versions.

The trigger is the **eviction attempt**, not the cordon. A cordon only says that
no new Pods should be scheduled there; it does not request that an existing
primary be moved. Reacting to a cordon alone would be too eager. The eviction
attempt is the point at which the drainer has actually decided to remove that
specific Pod, which is when the deadlock becomes real.

#### Why a webhook can see the blocked eviction

The kube-apiserver runs the admission chain before the eviction handler checks
the PodDisruptionBudget. A validating webhook can therefore observe the primary
eviction even though the primary PDB would reject it. If the webhook denies the
request, the PDB is not decremented, so there is no disruption-budget leak.

This ordering is an implementation detail of the API server, not a public
promise. The design depends on it and must verify it against the supported
Kubernetes versions.

#### What the webhook does

For an eviction request, the webhook allows the request unless all of the
following are true:

- the target Pod is a CNPG instance and the current primary;
- the target Pod is on a cordoned or otherwise unschedulable node;
- every CNPG instance is scheduled and hosted on a cordoned node;
- no replica is on an uncordoned node, so the normal CNPG switchover path cannot
  resolve the situation;
- the cluster is healthy enough to act: not already switching over, and no
  other disruption or recovery is in flight;
- at least one remedy is enabled for this cluster; the operator makes the final
  safety decision.

In that case the webhook:

1. records the request so the operator can act asynchronously;
2. denies the eviction with a retryable status (`429 Too Many Requests`), so the
   drainer retries after the primary has moved;
3. leaves the actual remedy to the operator.

If the webhook cannot determine that the request is a genuine deadlock, or if no
remedy is possible, it allows the request and lets the existing PDB and CNPG
behavior apply. It must not deny forever.

The webhook must not become a cluster-wide eviction dependency. If it is
unavailable, evictions must still reach the PDB. With PDBs enabled, that fails
safely into the existing stall. Running this feature with PDBs disabled is
unsupported.

#### Scope of the signal

The webhook observes only the eviction API. Direct Pod deletion, node-pressure
eviction, and clients that bypass eviction are outside its reach. A drainer that
gives up instead of retrying a denied eviction is also outside the guarantee:
the operator may complete the remedy, but the node is freed only when the
drainer retries.

### 3.3 Deletion remedy (default)

The operator removes one healthy replica. CNPG rebuilds it on an uncordoned
replacement node. Once the new replica is ready and streaming, the normal CNPG
switchover path moves the primary to it. The old primary is then a replica and
can be evicted under the replica PDB.

This gives **one switchover**. The cost is that the cluster temporarily has
`instances - 2` replicas: one replica was removed, and the replacement is not
ready yet.

Deletion is allowed only when:

- the cluster has at least three instances, so at least one replica remains
  after the deletion;
- at least one other ready replica exists;
- the configured synchronous-replication guarantee still holds after the
  deletion: do not remove the only synchronous standby, and require an explicit
  opt-in if `minSyncReplicas` cannot be honored;
- the replacement can actually be scheduled: shared/network storage, or a
  supported PVC recreation procedure. With node-local storage, deleting the Pod
  alone can leave the replacement Pending on the cordoned node, removing
  redundancy without unblocking the drain;
- no other switchover or remedy is in progress.

If these conditions are not met, the operator must not delete a replica. Leaving
the old stall is safer than a self-inflicted loss of HA.

### 3.4 Promotion remedy (opt-in)

The operator promotes a healthy replica that is still on a cordoned node. The
old primary becomes a replica, the drainer evicts it, and the new primary stays
on its cordoned node until CNPG creates a replacement on an uncordoned node.
The normal switchover path then moves the primary to that replacement.

This causes **two or more switchovers** in the common three-node case. The
cluster has `instances - 1` replicas immediately after the forced promotion.
Once the old primary, now a replica, is evicted, it drops to `instances - 2`
replicas until the replacement is ready. Promotion therefore does not preserve
an extra replica for the whole operation. Its advantage is that it moves the
primary before a replica is deleted or evicted, and it does not require a ready
replacement or a new node to make the first move.

Promotion is the right choice when avoiding the loss of the only replica before
the switchover is more important than the number of switchovers, for example:

- two-instance clusters with `minSyncReplicas: 1`, where deletion would remove
  the only synchronous standby;
- clusters with a hard requirement not to lose a replica before the switchover;
- environments where no replacement node is available yet, but freeing the
  current node is still useful.

Promotion must preserve all existing CNPG switchover preconditions. The only
check being relaxed is "the target node must be schedulable." The candidate must
still be ready, have an active WAL receiver, be unfenced, and be a valid target
for a planned switchover.

### 3.5 Safety requirements

These are mandatory for both remedies:

1. **Never delete or force-evict the primary.** Only replicas are eligible for
   deletion.
2. **Never delete the last replica.** After deletion, at least one replica must
   remain; for `instances == 2`, deletion is not the default remedy.
3. **Preserve the synchronous-replication contract.** Do not delete the only
   synchronous standby, prefer an asynchronous victim, and require an explicit
   choice when `minSyncReplicas` cannot be honored.
4. **Never promote an untrusted replica.** Use CNPG's readiness, WAL-receiver,
   fencing, and availability checks. "Cordoned" must not imply "unhealthy."
5. **No split brain and no bypassed failover.** Never promote without demoting
   the old primary through the existing switchover procedure, and never start a
   second switchover while one is in progress.
6. **Respect storage topology.** Deletion is unsafe when the replacement cannot
   be scheduled, especially with node-local storage and PVC node affinity.
7. **Serialize remedies per cluster.** One deletion or promotion at a time; a
   second request must wait or be rejected.
8. **Fail safe, not fail closed.** If the webhook cannot decide, allow the
   request and let the PDB decide. If the remedy cannot be completed, stop and
   leave the old stall. Do not repeatedly delete replicas.

### 3.6 Scope and non-goals

This design does not:

- make single-instance clusters drainable; there is no replica to promote or
  delete;
- handle node-pressure eviction, direct `kubectl delete pod`, or other paths
  that bypass the eviction API;
- remove the need for a maintenance window or the existing `reusePVC` workflow;
- guarantee zero downtime; every switchover is a brief write interruption;
- replace the existing CNPG switchover, failover, or storage procedures.

---

## 4. Summary

The deadlock is caused by the primary PDB correctly protecting the only primary
while CNPG correctly refuses to switch to a replica on an unschedulable node.
The proposed solution uses a validating `pods/eviction` webhook as a fast,
fail-open signal: when a real primary eviction would otherwise stall, the
webhook records the request and denies it with a retryable status, and the
operator performs an idempotent, guarded remedy. Deletion is the default because
it costs one switchover and temporarily leaves `instances - 2` replicas.
Promotion is an explicit opt-in for clusters that cannot lose a replica before
the switchover; it costs at least two switchovers and does not preserve an extra
replica for the whole operation. In both cases, CNPG's existing switchover
machinery remains the only way the primary is moved.
