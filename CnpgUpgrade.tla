-------------------- MODULE CnpgUpgrade -----------------------
VARIABLE nodeList, podList, nodeGroupStatus, cnpgStatus, pc

CONSTANT nodeDesiredSize, nodeMaxUnavailable, clusterName, clusterSize, cordonAllOldNodes

Types == INSTANCE KubernetesTypes

vars == <<nodeList, podList, nodeGroupStatus, cnpgStatus, pc>>

Cnpg == INSTANCE CnpgPods WITH size <- clusterSize,
                               unblockDrainWithPromotionEnabled <- FALSE,
                               unblockDrainWithDeletionEnabled <- TRUE

\* You can't drain a node where a PG primary is
ProtectPrimary(nodeInfo, currentPodList) == \A pod \in currentPodList : 
  Cnpg!PodIsPrimary(pod) => pod.nodeName /= nodeInfo.name

\* You can't drain a node if this means turning all the replicas down
ProtectReplica(nodeInfo, currentPodList) == \E pod \in currentPodList : 
   /\ ~Cnpg!PodIsPrimary(pod)
   /\ pod.nodeName /= nodeInfo.name

IsNodeDrainable(nodeInfo, currentPodList) == /\ ProtectPrimary(nodeInfo, currentPodList) 
                                             /\ ProtectReplica(nodeInfo, currentPodList)

NodeGroup == INSTANCE NodeGroup WITH desiredSize <- nodeDesiredSize, 
                                     maxUnavailable <- nodeMaxUnavailable, 
                                     status <- nodeGroupStatus

Scheduler == INSTANCE Scheduler

ASSUME Cnpg!ConstantAssumptions
ASSUME NodeGroup!ConstantAssumptions

---------------------------------------------------------------

Init == /\ NodeGroup!Init
        /\ Cnpg!Init
        /\ Scheduler!Init
        /\ pc=""

NodeGroupNext == NodeGroup!Next /\ UNCHANGED <<cnpgStatus>>
CnpgNext == Cnpg!Next /\ UNCHANGED <<nodeList, nodeGroupStatus>>
SchedulerNext == Scheduler!Next /\ UNCHANGED <<nodeList, nodeGroupStatus, cnpgStatus>>

Next == \/ NodeGroupNext
        \/ CnpgNext
        \/ SchedulerNext

Spec == Init /\ [][Next]_vars

FairSpec == /\ Spec 
            /\ WF_vars(NodeGroupNext)
            /\ WF_vars(CnpgNext)
            /\ WF_vars(SchedulerNext)

---------------------------------------------------------------

TypingInvariant == /\ Cnpg!TypingInvariant
                   /\ Cnpg!PodNamesAreValid
                   /\ NodeGroup!TypingInvariant

ImagesAlignedWhenNotUpgrading == NodeGroup!ImagesAlignedWhenNotUpgrading
CorrectSizeWhenNotUpgrading == NodeGroup!CorrectSizeWhenNotUpgrading
CorrectSizeWhenUpgrading == NodeGroup!CorrectSizeWhenUpgrading
MaxUnavailableHonored == NodeGroup!MaxUnavailableHonored
SinglePrimary == Cnpg!SinglePrimary
NoDuplicateNodes == Types!NoDuplicateNodes(nodeList)
NoDuplicatePods == Types!NoDuplicatePods(podList)

---------------------------------------------------------------

AlwaysFinishUpgrade == NodeGroup!AlwaysFinishUpgrade

===============================================================
