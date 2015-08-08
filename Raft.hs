{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE BangPatterns #-}


module VerdiRaft.Raft where

import Numeric.Natural
--import Data.Data (Data,Typeable)
--import GHC.Generics (Generic)
import Data.Set
import VerdiRaft.RaftData as RD

newtype Term = Term { unTerm :: Natural } deriving (Eq,Ord, Show)

newtype LogIndex = LogIndex { unLogIndex :: Natural } deriving (Eq,Ord, Show)

newtype Name = Name { unName :: Natural  } deriving (Eq,  Ord, Show)

data Input = Input deriving (Eq,Ord,Show)
data Output = Output deriving (Eq,Ord,Show)


--- the verdi raft doesn't deal with changing membership
nodes :: Set Name
nodes = undefined

data Entry = Entry
    {eAt :: Name
    ,eClient :: Natural
    ,eId :: LogIndex
    ,eIndex :: LogIndex
    ,eTerm :: Term
    ,eInput :: Input
    } deriving (Eq,Ord,Show)

data Msg = RequestVote Term Name LogIndex Term
         | RequestVoteReply Term Bool
         | AppendEntries Term Name LogIndex Term [Entry] LogIndex
         | AppendEntriesReply
         deriving (Eq,Ord,Show)

data RaftInput = Timeout
               | ClientRequest Natural Natural Input
               deriving (Eq,Ord,Show)

data RaftOut = NotLeader Natural Natural
             | ClientResponse Natural Natural Output
             deriving (Eq,Ord,Show)

data ServerType = Follower
                | Candidate
                | Leader
                deriving (Eq,Ord,Show)

findAtIndex :: [Entry] -> LogIndex -> Maybe Entry
findAtIndex [] _ = Nothing
findAtIndex (e:es) i
  | eIndex e ==  i = Just e
  | eIndex e  < i = Nothing
  | otherwise = findAtIndex es i

findGtIndex :: [Entry] -> LogIndex -> [Entry]
findGtIndex [] _ = []
findGtIndex (e:es) i | eIndex e > i = e : findGtIndex es i
                     | otherwise = []

removeAfterIndex :: [Entry] -> LogIndex -> [Entry]
removeAfterIndex [] _ = []
removeAfterIndex logs@(e:es) i
  | eIndex e <= i = logs
  | otherwise = removeAfterIndex es i

maxIndex :: [Entry] -> LogIndex
maxIndex [] = LogIndex 0
maxIndex (e:_es) = eIndex e

maxTerm :: [Entry] -> Term
maxTerm [] = Term 0
maxTerm (e:_es) =  eTerm e


advanceCurrentTerm :: forall term
                                   name
                                   entry
                                   logIndex
                                   stateMachineData
                                   output.
                            Ord term =>
                            RaftData
                              term name entry logIndex ServerType stateMachineData output
                            -> term
                            -> RaftData
                                 term name entry logIndex ServerType stateMachineData output
advanceCurrentTerm state newTerm
      | newTerm > RD.currentTerm state =
              state{currentTerm=newTerm
                    ,votedFor = Nothing
                    ,rdType = Follower
                    ,leaderId = Nothing
                    }
      | otherwise = state


getNextIndex :: forall term
                             name
                             logIndex
                             serverType
                             stateMachineData
                             output.
                      (Eq name, Eq logIndex) =>
                      RaftData
                        term name Entry logIndex serverType stateMachineData output
                      -> [([(name, logIndex)], LogIndex)] -> LogIndex
getNextIndex state h = maybe  (maxIndex (RD.log state)) id $ lookup (RD.nextIndex state) h
>>>>>>> d10578eda543c995a1f38d6af779c3c9c86343d4




