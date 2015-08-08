{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE BangPatterns #-}


module VerdiRaft.Raft where

import Numeric.Natural
import Data.Data (Data,Typeable)
import GHC.Generics (Generic)
import Data.Set

newtype Term = Term { unTerm :: Natural } deriving (Eq,Ord, Show)

newtype LogIndex = LogIndex { unLogIndex :: Natural } deriving (Eq,Ord, Show)

newtype Name = Name { unName :: Natural  } deriving (Eq,  Ord, Show)

data Input = Input deriving (Eq,Ord,Show)
data Output = Output deriving (Eq,Ord,Show)


--- the verdi raft doesn't deal with changing membership
nodes :: Set Name
nodes = undefined

data Entry = Entry { eAt :: Name
                    ,eClient :: Natural
                    ,eId :: LogIndex
                    ,eIndex :: LogIndex
                    ,eTerm :: Term
                    ,eInput :: Input
                    } deriving (Eq,Ord,Show )

data Msg = RequestVote Term Name LogIndex Term
          | RequestVoteReply Term Bool
          | AppendEntries Term Name LogIndex Term [Entry] LogIndex
          | AppendEntriesReply
          deriving (Eq,Ord,Show)


data RaftInput = Timeout | ClientRequest Natural Natural Input
    deriving (Eq,Ord,Show)

data RaftOut = NotLeader  Natural Natural
        | ClientResponse Natural Natural Output
        deriving (Eq,Ord,Show)

data ServerType = Follower | Candidate | Leader
  deriving (Eq,Ord,Show)


findAtIndex :: [Entry] -> LogIndex -> Maybe Entry
findAtIndex [] _ = Nothing
findAtIndex (e:es)  i  | eIndex e ==  i = Just e
                       | eIndex < i = Nothing
                       | otherwise = findAtIndex es i

findGtIndex :: [Entry] -> LogIndex -> [Entry]
findGtIndex [] i = []
findGtIndex (e:es) i |



