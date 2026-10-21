------------------------ MODULE Utils ---------------------

LOCAL INSTANCE Sequences

RECURSIVE SetToSeq(_)
SetToSeq(S) ==
  IF S = {}
  THEN <<>>
  ELSE LET x == CHOOSE y \in S : TRUE
       IN <<x>> \o SetToSeq(S \ {x})

===========================================================
