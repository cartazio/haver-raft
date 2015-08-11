{-# LANGUAGE ScopedTypeVariables, GeneralizedNewtypeDeriving #-}

module VerdiRaft.Raft where

import Numeric.Natural
import Prelude hiding (log)
--import Data.Data (Data,Typeable)
--import GHC.Generics (Generic)
--import Data.Set(Set)
import VerdiRaft.RaftData as RD

type Term =  Natural

newtype LogIndex = LogIndex { unLogIndex :: Natural } deriving (Eq,Ord, Show,Num)

newtype Name = Name { unName :: Natural  } deriving (Eq,  Ord, Show,Num)

data Input = Input deriving (Eq,Ord,Show)
data Output = Output deriving (Eq,Ord,Show)

--- the verdi raft doesn't deal with changing membership
nodes ::  [Name]
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
          | AppendEntriesReply Term [Entry] Bool
          deriving (Eq,Ord,Show)

data RaftInput = Timeout | ClientRequest Natural Natural Input
    deriving (Eq,Ord,Show)

data RaftOutput = NotLeader  Natural Natural
        | ClientResponse Natural Natural Output
        deriving (Eq,Ord,Show)

data ServerType = Follower | Candidate | Leader
  deriving (Eq,Ord,Show)


findAtIndex :: [Entry] -> LogIndex -> Maybe Entry
findAtIndex [] _ = Nothing
findAtIndex (e:es) i
  | eIndex e ==  i = Just e
  | eIndex e  < i = Nothing
  | otherwise = findAtIndex es i

findGtIndex :: [Entry] -> LogIndex -> [Entry]
findGtIndex [] _i = []
findGtIndex (e:es) i
  | eIndex e > i = e : findGtIndex es i
  | otherwise = []

removeAfterIndex :: [Entry] -> LogIndex  -> [Entry]
removeAfterIndex [] _ = []
removeAfterIndex (e:es) i |  eIndex e <= i = e : es
                          | otherwise = removeAfterIndex es i

maxIndex :: [Entry] -> LogIndex
maxIndex [] = LogIndex 0
maxIndex (e:_es) = eIndex e

maxTerm :: [Entry] -> Term
maxTerm [] =  0
maxTerm (e:_es) = eTerm e

advanceCurrentTerm :: forall term name entry logIndex stateMachineData output . Ord term
                   => RaftData term name entry logIndex ServerType stateMachineData output
                   -> term
                   -> RaftData term name entry logIndex ServerType stateMachineData output
advanceCurrentTerm state newTerm
      | newTerm > RD.currentTerm state =
              state {currentTerm=newTerm
                    ,votedFor = Nothing
                    ,rdType = Follower
                    ,leaderId = Nothing
                    }
      | otherwise = state

getNextIndex :: forall term name  serverType stateMachineData output . (Eq name)
             => RaftData term name Entry LogIndex serverType stateMachineData output
             -> [([(name, LogIndex)], LogIndex)]
             -> LogIndex
getNextIndex state h = maybe (maxIndex (RD.log state)) id $ lookup (RD.nextIndex state) h

tryToBecomeLeader :: Name
                  -> RaftData Term Name Entry logIndex ServerType stateMachineData output
                  -> ( [RaftOutput]
                     , RaftData Term Name Entry logIndex ServerType stateMachineData output
                     , [(Name,Msg)])
tryToBecomeLeader me state =
    ([]
    ,state{rdType=Candidate, votedFor= Just me, votesReceived= [me], currentTerm=t}
    ,map (\node -> (node, RequestVote t me
                            (maxIndex (RD.log state))
                            (maxTerm (RD.log state))  )) $
            filter (\ h -> h == me) nodes)
        where
          t :: Natural
          t = 1 + currentTerm state

not_empty :: [a] -> Bool
not_empty [] = False
not_empty (_:_) = True

haveNewEntries :: forall term name logIndex serverType stateMachineData output .
                  RaftData term name Entry logIndex serverType stateMachineData output
               -> [Entry]
               -> Bool
haveNewEntries state entries = not_empty entries
  && (maybe True (\e -> (maxTerm entries) /= (eTerm e) ) $
       findAtIndex (RD.log state) (maxIndex entries))

handleAppendEntries :: Name
                    -> RaftData Term Name  Entry LogIndex ServerType stateMachineData output
                    -> Term
                    -> Name
                    -> LogIndex
                    -> Term
                    -> [Entry]
                    -> LogIndex
                    -> ( RaftData Term Name Entry LogIndex ServerType stateMachineData output
                       , Msg)
handleAppendEntries _me state t mleaderId prevLogIndex prevLogTerm entries leaderCommit =
    if currentTerm state > t then
       (state, AppendEntriesReply (currentTerm state) entries False)
    else if haveNewEntries state entries then
        ( (advanceCurrentTerm state t) {
              RD.log      = entries
             ,commitIndex = max (commitIndex state) (min leaderCommit (maxIndex entries ))
             ,rdType      = Follower
             ,leaderId    = Just mleaderId }
        , AppendEntriesReply t entries True)
    else case findAtIndex (RD.log state) prevLogIndex of
      Nothing -> (state, AppendEntriesReply (currentTerm state) entries False)
      Just e ->
        if  prevLogTerm /= (eTerm e) then (state, AppendEntriesReply (currentTerm state) entries False)
          else if haveNewEntries  state entries
            then
              let
                log' = removeAfterIndex (log state) prevLogIndex
                log'' = entries ++ log'
                 in
                  ( (advanceCurrentTerm state t) {
                         log         = log''
                        ,commitIndex = max (commitIndex state) (min leaderCommit (maxIndex log''))
                        ,rdType      = Follower
                        ,leaderId    = Just mleaderId}
                  , AppendEntriesReply t entries True)
            else ( (advanceCurrentTerm state t) {
                         rdType = Follower
                        ,leaderId = Just mleaderId}
                 , AppendEntriesReply t entries True)


listupsert :: Eq k => [(k,v)] -> k -> v -> [(k,v)]
listupsert [] k v = [(k,v)]
listupsert (a@(k1,_):as) k v | k1 == k = (k1,v) : as
                            | otherwise = a : listupsert as k v

assoc_set:: Eq k => [(k,v)] -> k -> v -> [(k,v)]
assoc_set = listupsert

assoc_default :: Eq k => [(k,v)] -> k -> v -> v
assoc_default ls k def = maybe def id $ lookup  k ls

handleAppendEntriesReply :: Eq name =>
                                     name
                                  -> RaftData
                                       term name Entry LogIndex serverType stateMachineData output
                                  -> name
                                  -> term
                                  -> [Entry]
                                  -> Bool
                                  -> (RaftData
                                        term name Entry LogIndex serverType stateMachineData output
                                    ,[(name,Msg)] )
handleAppendEntriesReply  me state src term entries result =
    if currentTerm state == term then
      if result then
        let index = maxIndex entries in
          (state{matchIndex=  assoc_set (matchIndex state) src
                  $ max (assoc_default (matchIndex state) src 0) index
                ,nextIndex= assoc_set (nextIndex state) src $
                            max (getNextIndex state src :: LogIndex) (1 + index :: LogIndex) }
            ,[])

          else undefined
          else undefined

