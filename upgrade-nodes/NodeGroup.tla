------------ MODULE NodeGroup -----------------

LOCAL INSTANCE KubernetesTypes
LOCAL INSTANCE FiniteSets
LOCAL INSTANCE Sequences
LOCAL INSTANCE Utils

\* A NodeGroup models the concept of a dynamic
\* set of nodes that are created, destroyed
\* and updated by a controller.
\*
\* EKS uses that concept extensively.
\*
\* We don't model the autoscaler concept here.

CONSTANT desiredSize, maxUnavailable, IsNodeDrainable(_, _), cordonAllOldNodes
VARIABLE nodeList, podList, status, pc

ASSUME \A n \in NodeInfo, p \in PodList : IsNodeDrainable(n, p) \in BOOLEAN
ASSUME cordonAllOldNodes \in BOOLEAN

\* Preconditions on the constants. Kept as an operator (instead of ASSUME) so a
\* TLC root module can assert it: TLC only checks ASSUME statements in the root
\* module, not in modules reached via INSTANCE.
ConstantAssumptions ==
    /\ maxUnavailable \in Nat
    /\ 0 < maxUnavailable
    /\ maxUnavailable < desiredSize
    /\ desiredSize + maxUnavailable <= Cardinality(NodeName)

-----------------------------------------------

NodeSeq == UNION { [1..n -> NodeInfo] : n \in 0..maxUnavailable }

NodeGroupStatus == [currentVersion: ImageVersion, targetVersion: ImageVersion, drainList: NodeSeq]

IsUpgrading(s) == s.currentVersion /= s.targetVersion
IsNotUpgrading(s) == ~IsUpgrading(s)

IsDraining(s) == s.drainList /= <<>>
IsNotDraining(s) == ~IsDraining(s)

-----------------------------------------------

vars == <<nodeList, podList, status>>

Init == /\ status = [targetVersion |-> 0, currentVersion |-> 0, drainList |-> <<>>]
        /\ nodeList = {}

ScaleUpAction == /\ Cardinality(nodeList) < desiredSize
                 /\ IsNotUpgrading(status)
                 /\ LET newNodeName == CHOOSE nodeName \in NodeName : nodeName \notin {node.name: node \in nodeList}
                    IN nodeList' = nodeList \cup {[name |-> newNodeName, imageVersion |-> status.currentVersion, cordoned |-> FALSE]}
                 /\ pc' = "ScaleUpAction"
                 /\ UNCHANGED <<podList, status>>

StartUpgrade == /\ Cardinality(nodeList) >= desiredSize
                /\ IsNotUpgrading(status)
                /\ nodeList' = IF cordonAllOldNodes THEN {[node EXCEPT !.cordoned=TRUE]: node \in nodeList} ELSE nodeList
                /\ pc' = "StartUpgrade"
                /\ LET newTargetVersion == CHOOSE imageVersion \in ImageVersion : imageVersion /= status.currentVersion
                   IN status' = [status EXCEPT !.targetVersion = newTargetVersion]
                /\ UNCHANGED podList

\* Choose up to maxUnavailable not-yet-upgraded nodes to drain and surge
\* their replacements in the same step. Creating a replacement before the
\* old node is terminated (next step) is what lets nodeList temporarily
\* exceed desiredSize.
SelectNodesToDrain == /\ IsUpgrading(status)
                      /\ IsNotDraining(status)
                      /\ \E newDrainList \in SUBSET {n \in nodeList : n.imageVersion = status.currentVersion} :
                            /\ Cardinality(newDrainList) <= maxUnavailable
                            /\ Cardinality(newDrainList) > 0
                            /\ LET availableNames == NodeName \ {n.name: n \in nodeList}
                                   newNodeNames == CHOOSE x \in SUBSET availableNames : Cardinality(x) = Cardinality(newDrainList)
                                   newNodes == {[name |-> n, imageVersion |-> status.targetVersion, cordoned |-> FALSE]: n \in newNodeNames}
                               IN /\ status' = [status EXCEPT !.drainList=SetToSeq(newDrainList)]
                                  /\ nodeList' = IF cordonAllOldNodes
                                                 THEN nodeList \cup newNodes 
                                                 ELSE (nodeList \ newDrainList) \cup {[n EXCEPT !.cordoned=TRUE]: n \in newDrainList} \cup newNodes
                                  /\ pc' = "SelectNodesToDrain"
                                  /\ UNCHANGED podList

\* Terminate one drained node at a time, now that its replacements are in place.
\*
\* Draining node-by-node (rather than the whole selected batch at once) gives a
\* more faithful trace of the real operation and lets TLC observe intermediate
\* states. Only the node at the head of drainList is removed in a step, and only
\* when IsNodeDrainable holds for it.
\*
\* We are mainly interested in the behavior happening when maxUnavailable=1
\* so this is not a real problem, but we may want to expand the model
\* in the future.
DrainNode == /\ IsUpgrading(status)
             /\ IsDraining(status)
             /\ LET drainingNode == Head(status.drainList)
                IN /\ IsNodeDrainable(drainingNode, podList)
                   /\ status' = [status EXCEPT !.drainList=Tail(status.drainList)]
                   /\ pc' = "DrainNode"
                   /\ nodeList' = nodeList \ {[drainingNode EXCEPT !.cordoned=TRUE]}
                   /\ podList' = {pod \in podList: pod.nodeName /= drainingNode.name}

FinishUpgrade == /\ IsUpgrading(status)
                 /\ \A n \in nodeList : n.imageVersion = status.targetVersion
                 /\ status' = [status EXCEPT !.currentVersion=status.targetVersion]
                 /\ pc' = "FinishUpgrade"
                 /\ UNCHANGED <<nodeList, podList>>

Next == \/ ScaleUpAction
        \/ StartUpgrade
        \/ SelectNodesToDrain
        \/ DrainNode
        \/ FinishUpgrade

-----------------------------------------------

Spec == Init /\ [][Next]_vars

\* We assume weak fairness only for the upgrade process
FairSpec == /\ Spec
            /\ WF_vars(SelectNodesToDrain)
            /\ WF_vars(DrainNode)
            /\ WF_vars(FinishUpgrade)

-----------------------------------------------

ImagesAlignedWhenNotUpgrading == IsNotUpgrading(status) => Cardinality({node.imageVersion: node \in nodeList}) <= 1
CorrectSizeWhenNotUpgrading == IsNotUpgrading(status) => Cardinality(nodeList) <= desiredSize
CorrectSizeWhenUpgrading == IsUpgrading(status) => Cardinality(nodeList) <= desiredSize + maxUnavailable
MaxUnavailableHonored == Len(status.drainList) <= maxUnavailable

TypingInvariant == /\ NoDuplicateNodes(nodeList)
                   /\ nodeList \in NodeList
                   /\ status \in NodeGroupStatus
                   /\ podList \in PodList

-----------------------------------------------

AlwaysFinishUpgrade == IsUpgrading(status) ~> IsNotUpgrading(status)

===============================================
