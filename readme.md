# What is Haver-Raft?
its a trusty haversack for ordered reliable message deliver based consensus using
the Raft algorithm!

Haver-Raft is a Raft consensus implementation in Haskell derived from the
verified Coq Raft implementation by the Verdi Project.
The initial haver-raft implementation should match up almost syntactically with
commit 093061a1c310ec55af4e354e7388dce308d910f7 of
https://github.com/uwplse/verdi/blob/master/raft/Raft.v

# When should I use Haver-Raft?
You probably shouldn't, except as a fully explicit reference implementation of Raft
that has a few tweaks over the verified Verdi implementation to make it sort of usable.
If you want to modify it, fork it! This code is meant to stay faithful to the proven correct model code
so as to maintain correctness. So design improvments aren't on the table. Sorry!

# Why Did you write this?
Because before writing a better designed version of Raft/Consensus for our own uses,
we wanted to make sure that we wrote it correctly least once first!

