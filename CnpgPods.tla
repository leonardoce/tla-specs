---------------- MODULE CnpgPods ---------------

\* This is a simple module that just makes now Pods for a CNPG
\* cluster, without scheduling them.

EXTENDS Naturals, Sequences, FiniteSets, TLC
LOCAL INSTANCE KubernetesTypes

CONSTANT clusterName, size, unblockDrainWithPromotionEnabled, unblockDrainWithDeletionEnabled
VARIABLE podList, nodeList, cnpgStatus, nodeGroupStatus, pc

ASSUME unblockDrainWithPromotionEnabled \in BOOLEAN
ASSUME unblockDrainWithDeletionEnabled \in BOOLEAN

vars == <<podList, nodeList, cnpgStatus, nodeGroupStatus>>

PodNameOf(i) == clusterName \o "-" \o ToString(i)
ExpectedPodNames == {PodNameOf(i) : i \in 1..size}
CnpgStatus == [primary: ExpectedPodNames \cup {""}]

\* Internal: generate the labels used by a CNPG Pod depending
\* on it being a primary or not
cnpgLabels(primary) == {
    [name |-> "role", value |-> IF primary THEN "primary" ELSE "replica"]
  }

\* Internal: generate a new Pod info for a CNPG pod
newPodInfo(name, primary) == 
  [
    name |-> name,
    nodeName |-> "",
    labels |-> cnpgLabels(primary)
  ]

\* Internal: mark a podInfo as primary
markPrimary(info) == [info EXCEPT !.labels=cnpgLabels(TRUE)]

\* Internal: mark a podInfo as replica
markReplica(info) == [info EXCEPT !.labels=cnpgLabels(FALSE)]

\* This checks whether a PodInfo belongs to a CNPG primary Pod
PodIsPrimary(pod) == \E label \in pod.labels : label.name="role" /\ label.value="primary"
PodIsReplica(pod) == ~PodIsPrimary(pod)

------------------------------------------------

\* Creates a new Pod and elects it as primary if it is the first one
CreatePod ==
    /\ Cardinality(podList) < size
    /\ LET currentPodNames == {p.name : p \in podList}
           newPodName == CHOOSE n \in ExpectedPodNames \ currentPodNames: TRUE
           primaryName == IF cnpgStatus.primary = "" THEN newPodName ELSE cnpgStatus.primary
       IN /\ podList' = podList \cup {newPodInfo(newPodName, primaryName=newPodName)}
          /\ cnpgStatus' = [primary |-> primaryName]
          /\ pc' = "CreatePod"
          /\ UNCHANGED <<nodeGroupStatus, nodeList>>

\* When the primary is sitting in a cordoned node and exists
\* a replica whose node is not cordoned, we promote that replica.
AutoswitchWhenPrimaryCordoned ==
  /\ nodeGroupStatus.drainList /= <<>>
  /\ \E primaryPod, replicaPod \in podList :
        /\ PodIsPrimary(primaryPod)
        /\ PodIsReplica(replicaPod)
        /\ PodIsScheduledOnCordonedNode(primaryPod, nodeList)
        /\ PodIsScheduledOnNotCordonedNode(replicaPod, nodeList)
        /\ podList' = (podList \ {primaryPod, replicaPod}) \cup {markReplica(primaryPod), markPrimary(replicaPod)}
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
      /\ podList' = (podList \ {primaryPod, replicaPod}) \cup {markReplica(primaryPod), markPrimary(replicaPod)}
      /\ cnpgStatus' = [primary |-> replicaPod.name]
      /\ pc' = "UnblockDrainAllNodesCordonedWithPromotion"
      /\ UNCHANGED <<nodeGroupStatus, nodeList>>

\* Unblocks a node being drained if every node where CNPG is running is
\* cordoned and the primary is being drained. It does that by removing
\* a random replica.
UnblockDrainAllNodesCordonedWithDeletion ==
  /\ unblockDrainWithDeletionEnabled
  /\ nodeGroupStatus.drainList /= <<>>
  /\ ~ENABLED CreatePod
  /\ ~ENABLED AutoswitchWhenPrimaryCordoned
  /\ \A pod \in podList : pod.nodeName /= ""
  /\ \A node \in nodeList, pod \in podList : pod.nodeName=node.name => node.cordoned
  /\ \E replicaPod \in podList : 
      /\ PodIsReplica(replicaPod)
      /\ podList' = (podList \ {replicaPod})
      /\ pc' = "UnblockDrainAllNodesCordonedWithDeletion"
      /\ UNCHANGED <<nodeGroupStatus, nodeList, cnpgStatus>>

Next == \/ CreatePod
        \/ UnblockDrainAllNodesCordonedWithPromotion
        \/ UnblockDrainAllNodesCordonedWithDeletion
        \/ AutoswitchWhenPrimaryCordoned

------------------------------------------------

Init == /\ podList = {}
        /\ cnpgStatus = [primary |-> ""]
Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(CreatePod)

------------------------------------------------

ConstantAssumptions ==
    /\ clusterName \in STRING
    /\ clusterName /= ""
    /\ size \in Nat
    /\ size > 0

ASSUME ConstantAssumptions

TypingInvariant == /\ podList \in PodList
                   /\ cnpgStatus \in CnpgStatus

PodNamesAreValid == \A p \in podList : p.name \in ExpectedPodNames
SinglePrimary == \A p1, p2 \in podList : 
  PodIsPrimary(p1) /\ PodIsPrimary(p2) => p1=p2 /\ cnpgStatus.primary=p1.name

================================================
