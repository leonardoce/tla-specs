---------------- MODULE CnpgPods ---------------

\* This is a simple module that just makes now Pods for a CNPG
\* cluster, without scheduling them.

EXTENDS Naturals, Sequences, FiniteSets, TLC

LOCAL INSTANCE KubernetesTypes
LOCAL INSTANCE CnpgTypes

CONSTANT clusterName, size
VARIABLE podList, nodeList, cnpgStatus, nodeGroupStatus, pc

vars == <<podList, nodeList, cnpgStatus, nodeGroupStatus>>

PodNameOf(i) == clusterName \o "-" \o ToString(i)
ExpectedPodNames == {PodNameOf(i) : i \in 1..size}

\* Internal: generate a new Pod info for a CNPG pod
newPodInfo(name, primary) == 
  [
    name |-> name,
    nodeName |-> "",
    labels |-> CnpgLabels(primary)
  ]

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
        /\ podList' = (podList \ {primaryPod, replicaPod}) \cup {MarkReplica(primaryPod), MarkPrimary(replicaPod)}
        /\ cnpgStatus' = [primary |-> replicaPod.name]
        /\ pc' = "AutoswitchWhenPrimaryCordoned"
        /\ UNCHANGED <<nodeGroupStatus, nodeList>>

Next == \/ CreatePod
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
