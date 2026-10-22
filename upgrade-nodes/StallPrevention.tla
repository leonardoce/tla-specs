---------------------- MODULE StallPrevention --------------------
EXTENDS Sequences

CONSTANT clusterName, size, unblockDrainWithPromotionEnabled, unblockDrainWithDeletionEnabled

LOCAL INSTANCE CnpgTypes
LOCAL INSTANCE KubernetesTypes

VARIABLE podList, nodeList, cnpgStatus, nodeGroupStatus, pc

ASSUME unblockDrainWithPromotionEnabled \in BOOLEAN
ASSUME unblockDrainWithDeletionEnabled \in BOOLEAN

\* When the primary is sitting in a cordoned node and exists
\* a replica whose node is not cordoned, we promote that replica.
AutoswitchWhenPrimaryCordoned ==
  /\ nodeGroupStatus.drainList /= <<>>
  /\ \E primaryPod, replicaPod \in podList :
        /\ PodIsPrimary(primaryPod)
        /\ PodIsReplica(replicaPod)
        /\ PodIsScheduledOnCordonedNode(primaryPod, nodeList)
        /\ PodIsScheduledOnNotCordonedNode(replicaPod, nodeList)
        /\ podList' = (podList \ {primaryPod, replicaPod}) \cup {MarkReplica(primaryPod), MarkPrimary(replicaPod)}
        /\ cnpgStatus' = [primary |-> replicaPod.name]
        /\ pc' = "AutoswitchWhenPrimaryCordoned"
        /\ UNCHANGED <<nodeGroupStatus, nodeList>>


\* Unblocks a node being drained if every node where CNPG is running is
\* cordoned and the primary is being drained. It does that by promoting
\* a random replica.
UnblockDrainAllNodesCordonedWithPromotion ==
  /\ unblockDrainWithPromotionEnabled
  /\ nodeGroupStatus.drainList /= <<>>
  /\ \A node \in nodeList, pod \in podList : pod.nodeName=node.name => node.cordoned
  /\ \E primaryPod, replicaPod \in podList : 
      /\ PodIsPrimary(primaryPod)
      /\ PodIsReplica(replicaPod)
      /\ PodIsScheduledOnCordonedNode(replicaPod, nodeList)
      /\ primaryPod.nodeName=Head(nodeGroupStatus.drainList).name
      /\ podList' = (podList \ {primaryPod, replicaPod}) \cup {MarkReplica(primaryPod), MarkPrimary(replicaPod)}
      /\ cnpgStatus' = [primary |-> replicaPod.name]
      /\ pc' = "UnblockDrainAllNodesCordonedWithPromotion"
      /\ UNCHANGED <<nodeGroupStatus, nodeList>>

\* Unblocks a node being drained if every node where CNPG is running is
\* cordoned and the primary is being drained. It does that by removing
\* a random replica.
UnblockDrainAllNodesCordonedWithDeletion ==
  /\ unblockDrainWithDeletionEnabled
  /\ nodeGroupStatus.drainList /= <<>>
  /\ Cardinality(podList) >= size        \* No need to scale up
  /\ ~ENABLED AutoswitchWhenPrimaryCordoned
  /\ \A pod \in podList : pod.nodeName /= ""
  /\ \A node \in nodeList, pod \in podList : pod.nodeName=node.name => node.cordoned
  /\ \E replicaPod \in podList : 
      /\ PodIsReplica(replicaPod)
      /\ podList' = (podList \ {replicaPod})
      /\ pc' = "UnblockDrainAllNodesCordonedWithDeletion"
      /\ UNCHANGED <<nodeGroupStatus, nodeList, cnpgStatus>>

------------------------------------------------------------------

Next == \/ UnblockDrainAllNodesCordonedWithPromotion
        \/ UnblockDrainAllNodesCordonedWithDeletion

==================================================================