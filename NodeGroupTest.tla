------------ MODULE NodeGroupTest -----------------
VARIABLE nodeList, podList, status, pc
CONSTANT desiredSize, maxUnavailable

vars == <<nodeList, podList, status, pc>>

IsNodeDrainable(n, p) == TRUE

NodeGroup == INSTANCE NodeGroup WITH
  desiredSize <- desiredSize,
  maxUnavailable <- maxUnavailable,
  IsNodeDrainable <- IsNodeDrainable,
  status <- status

Init == NodeGroup!Init /\ pc = "" /\ podList = {}
Next == NodeGroup!Next
Spec == Init /\ [][Next]_<<nodeList, podList, status, pc>>
FairSpec == Spec /\ WF_vars(NodeGroup!Next)

TypingInvariant == NodeGroup!TypingInvariant
ImagesAlignedWhenNotUpgrading == NodeGroup!ImagesAlignedWhenNotUpgrading
CorrectSizeWhenNotUpgrading == NodeGroup!CorrectSizeWhenNotUpgrading
CorrectSizeWhenUpgrading == NodeGroup!CorrectSizeWhenUpgrading
MaxUnavailableHonored == NodeGroup!MaxUnavailableHonored
AlwaysFinishUpgrade == NodeGroup!AlwaysFinishUpgrade

ASSUME NodeGroup!ConstantAssumptions
===================================================
