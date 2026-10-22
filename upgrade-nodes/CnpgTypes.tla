-------------------------------- MODULE CnpgTypes -----------------------------
LOCAL INSTANCE KubernetesTypes

\* Generate the labels used by a CNPG Pod depending
\* on it being a primary or not
CnpgLabels(primary) == {
    [name |-> "role", value |-> IF primary THEN "primary" ELSE "replica"]
  }

\* This checks whether a PodInfo belongs to a CNPG primary Pod
PodIsPrimary(pod) == \E label \in pod.labels : label.name="role" /\ label.value="primary"
PodIsReplica(pod) == ~PodIsPrimary(pod)

MarkPrimary(info) == [info EXCEPT !.labels=CnpgLabels(TRUE)]
MarkReplica(info) == [info EXCEPT !.labels=CnpgLabels(FALSE)]

CnpgStatus == [primary: STRING]

===============================================================================