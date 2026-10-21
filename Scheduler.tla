---------------------- MODULE Scheduler -------------------
VARIABLE podList, nodeList, pc

vars == <<podList, nodeList, pc>>

UnscheduledPods == {pod \in podList : pod.nodeName = ""}
AvailableNodes == {node \in nodeList : ~node.cordoned /\ \A pod \in podList : pod.nodeName /= node.name}
SchedulePod(pod, node) == (podList \ {pod}) \cup {[pod EXCEPT !.nodeName=node.name]}

\* We schedule one Pod per node. This module needs to emulate
\* the anti-affity behavior CNPG likes.
SchedulePodAction == \E pod \in UnscheduledPods : \E node \in AvailableNodes : 
   /\ podList' = SchedulePod(pod, node)
   /\ pc' = "SchedulePodAction"
   /\ UNCHANGED <<nodeList>>

-----------------------------------------------------------

Init == pc=""
Next == SchedulePodAction

Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(SchedulePodAction)

===========================================================
