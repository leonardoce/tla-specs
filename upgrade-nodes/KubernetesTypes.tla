------------- MODULE KubernetesTypes ----------------
EXTENDS Naturals, FiniteSets

\* This discrete explicit list of names helps keeping the
\* state space small.
NodeName == {"red", "green", "blue", "yellow", "pink",
             "black", "white", "magenta", "fucsia", "scarlet",
             "cyan", "teal", "navy", "olive", "maroon",
             "silver", "gold", "coral", "violet", "indigo"}

\* The type of pod names
PodName == STRING

\* Labels applied to objects
Mapping == [name: STRING, value: STRING]
Labels == SUBSET Mapping

\* Having two distinct image versions allows to model
\* the node upgrade process
ImageVersion == 0..1

\* NodeInfo is stored for every node
NodeInfo == [name: NodeName, cordoned: BOOLEAN, imageVersion: ImageVersion]

\* NodeList is a collection of nodes, where each
\* Node is identified by its name
NodeList == SUBSET NodeInfo

\* PodInfo is a stored for every Pod
PodInfo == [name: PodName, nodeName: NodeName \cup {""}, labels: Labels]

\* PodList is a collection of pods, where each
\* Pod is identified by its name
PodList == SUBSET PodInfo

\* PodIsScheduledOnCordonedNode is true when the passed
\* podInfo is scheduled on a node that is cordoned.
PodIsScheduledOnCordonedNode(podInfo, nodeList) ==
  \E node \in nodeList : node.name = podInfo.nodeName /\ node.cordoned
  
\* PodIsScheduledOnNotCordonedNode is true when the passed
\* podInfo is scheduled on a node that is not cordoned.
PodIsScheduledOnNotCordonedNode(podInfo, nodeList) ==
  \E node \in nodeList : node.name = podInfo.nodeName /\ ~node.cordoned

------------------------------------------------------

NoDuplicateNodes(nodeList) == Cardinality(nodeList) = Cardinality({node.name: node \in nodeList})
NoDuplicatePods(podList) == Cardinality(podList) = Cardinality({pod.name: pod \in podList})

======================================================
