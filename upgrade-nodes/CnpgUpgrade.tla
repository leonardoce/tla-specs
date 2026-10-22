-------------------- MODULE CnpgUpgrade -----------------------
VARIABLE nodeList, podList, nodeGroupStatus, cnpgStatus, pc

CONSTANT nodeDesiredSize, nodeMaxUnavailable, clusterName, clusterSize, cordonAllOldNodes, unblockDrainWithPromotionEnabled, unblockDrainWithDeletionEnabled

Types == INSTANCE KubernetesTypes
CnpgTypes == INSTANCE CnpgTypes

vars == <<nodeList, podList, nodeGroupStatus, cnpgStatus, pc>>

Cnpg == INSTANCE CnpgPods WITH size <- clusterSize

\* You can't drain a node where a PG primary is
ProtectPrimary(nodeInfo, currentPodList) == \A pod \in currentPodList : 
  CnpgTypes!PodIsPrimary(pod) => pod.nodeName /= nodeInfo.name

\* You can't drain a node if this means turning all the replicas down
ProtectReplica(nodeInfo, currentPodList) == \E pod \in currentPodList : 
   /\ ~CnpgTypes!PodIsPrimary(pod)
   /\ pod.nodeName /= nodeInfo.name

IsNodeDrainable(nodeInfo, currentPodList) == /\ ProtectPrimary(nodeInfo, currentPodList) 
                                             /\ ProtectReplica(nodeInfo, currentPodList)

NodeGroup == INSTANCE NodeGroup WITH desiredSize <- nodeDesiredSize, 
                                     maxUnavailable <- nodeMaxUnavailable, 
                                     status <- nodeGroupStatus
Scheduler == INSTANCE Scheduler

StallPrevention == INSTANCE StallPrevention WITH size <- clusterSize

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
StallPreventionNext == StallPrevention!Next /\ UNCHANGED <<nodeList, nodeGroupStatus>>

Next == \/ NodeGroupNext
        \/ CnpgNext
        \/ SchedulerNext
        \/ StallPreventionNext

Spec == Init /\ [][Next]_vars

FairSpec == /\ Spec 
            /\ WF_vars(NodeGroupNext)
            /\ WF_vars(CnpgNext)
            /\ WF_vars(SchedulerNext)
            /\ WF_vars(StallPreventionNext)

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
