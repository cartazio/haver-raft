{-# LANGUAGE ScopedTypeVariables, GeneralizedNewtypeDeriving, KindSignatures #-}

module VerdiRaft.Raft where

import Numeric.Natural
import Prelude hiding (log,pred)
--import Data.Data (Data,Typeable)
--import GHC.Generics (Generic)
--import Data.Set(Set)
import Data.Maybe (isJust, fromMaybe)
import VerdiRaft.RaftData as RD

type Term =  Natural

newtype LogIndex = LogIndex { unLogIndex :: Natural } deriving (Eq,Ord, Show,Num)

newtype Name = Name { unName :: Natural  } deriving (Eq,  Ord, Show,Num)

data Input = Input deriving (Eq,Ord,Show)
data Output = Output deriving (Eq,Ord,Show)

--- the verdi raft doesn't deal with changing membership
nodes ::  [Name]
nodes = undefined

data Entry = Entry {
   eAt :: Name
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

data RaftInput = Timeout
               | ClientRequest Natural Natural Input
               deriving (Eq,Ord,Show)

data RaftOutput = NotLeader  Natural Natural
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
  | eIndex e < i = Nothing
  | otherwise = findAtIndex es i

findGtIndex :: [Entry] -> LogIndex -> [Entry]
findGtIndex [] _i = []
findGtIndex (e:es) i
  | eIndex e > i = e : findGtIndex es i
  | otherwise    = []

removeAfterIndex :: [Entry] -> LogIndex  -> [Entry]
removeAfterIndex [] _ = []
removeAfterIndex (e:es) i
  | eIndex e <= i = e : es
  | otherwise = removeAfterIndex es i

maxIndex :: [Entry] -> LogIndex
maxIndex [] = LogIndex 0
maxIndex (e:_es) = eIndex e

maxTerm :: [Entry] -> Term
maxTerm [] =  0
maxTerm (e:_es) = eTerm e

advanceCurrentTerm :: forall term name entry logIndex stateMachineData output
                    . Ord term
                   => RaftData term name entry logIndex ServerType stateMachineData output
                   -> term
                   -> RaftData term name entry logIndex ServerType stateMachineData output
advanceCurrentTerm state newTerm
      | newTerm > RD.currentTerm state =
              state {currentTerm = newTerm
                    ,votedFor = Nothing
                    ,rdType = Follower
                    ,leaderId = Nothing
                    }
      | otherwise = state

getNextIndex :: forall term name serverType stateMachineData output
              . Eq name
             => RaftData term name Entry LogIndex serverType stateMachineData output
             -> name
             -> LogIndex
getNextIndex state h = assocDefault (nextIndex state) h (maxIndex (log state))

tryToBecomeLeader :: Name
                  -> RaftData Term Name Entry logIndex ServerType stateMachineData output
                  -> ( [RaftOutput]
                     , RaftData Term Name Entry logIndex ServerType stateMachineData output
                     , [(Name,Msg)])
tryToBecomeLeader me state =
    ([]
    ,state {rdType = Candidate
           ,votedFor = Just me
           ,votesReceived = [me]
           ,currentTerm = t}
    ,map (\node -> (node, RequestVote t me
                            (maxIndex (RD.log state))
                            (maxTerm (RD.log state)))
         ) $ filter (\h -> h == me) nodes)
        where
          t :: Natural
          t = 1 + currentTerm state

notEmpty :: [a] -> Bool
notEmpty [] = False
notEmpty (_:_) = True

haveNewEntries :: forall term name logIndex serverType stateMachineData output
                . RaftData term name Entry logIndex serverType stateMachineData output
               -> [Entry]
               -> Bool
haveNewEntries state entries =
  notEmpty entries && case findAtIndex (RD.log state) (maxIndex entries) of
                        Just e -> maxTerm entries /= eTerm e
                        Nothing -> False

handleAppendEntries :: Name
                    -> RaftData Term Name Entry LogIndex ServerType stateMachineData output
                    -> Term
                    -> Name
                    -> LogIndex
                    -> Term
                    -> [Entry]
                    -> LogIndex
                    -> (RaftData Term Name Entry LogIndex ServerType stateMachineData output
                       ,Msg)
handleAppendEntries _me state t mleaderId prevLogIndex prevLogTerm entries leaderCommit =
    if currentTerm state > t then
       (state, AppendEntriesReply (currentTerm state) entries False)
    else if haveNewEntries state entries then
        ((advanceCurrentTerm state t) {
              RD.log      = entries
             ,commitIndex = max (commitIndex state) (min leaderCommit (maxIndex entries ))
             ,rdType      = Follower
             ,leaderId    = Just mleaderId }
        ,AppendEntriesReply t entries True)
    else case findAtIndex (RD.log state) prevLogIndex of
      Nothing -> (state, AppendEntriesReply (currentTerm state) entries False)
      Just e ->
        if prevLogTerm /= eTerm e then (state, AppendEntriesReply (currentTerm state) entries False)
          else if haveNewEntries  state entries
            then
              let
                log' = removeAfterIndex (log state) prevLogIndex
                log'' = entries ++ log'
                 in
                  ((advanceCurrentTerm state t) {
                         log         = log''
                        ,commitIndex = max (commitIndex state) (min leaderCommit (maxIndex log''))
                        ,rdType      = Follower
                        ,leaderId    = Just mleaderId}
                  ,AppendEntriesReply t entries True)
            else ((advanceCurrentTerm state t) {
                         rdType   = Follower
                        ,leaderId = Just mleaderId}
                 ,AppendEntriesReply t entries True)


listupsert :: Eq k => [(k,v)] -> k -> v -> [(k,v)]
listupsert [] k v = [(k,v)]
listupsert (a@(k1,_):as) k v | k1 == k = (k1,v) : as
                            | otherwise = a : listupsert as k v

assocSet:: Eq k => [(k,v)] -> k -> v -> [(k,v)]
assocSet = listupsert

assocDefault :: Eq k => [(k,v)] -> k -> v -> v
assocDefault ls k def = maybe def id $ lookup k ls

pred :: (Num a, Ord a ,Eq a) => a -> a
pred n | n <= 0 = 0
       | otherwise = n -1

handleAppendEntriesReply :: forall t term name stateMachineData output
                         .  (Ord term, Eq name)
                         => t
                         -> RaftData term name Entry LogIndex ServerType stateMachineData output
                         -> name
                         -> term
                         -> [Entry]
                         -> Bool
                         -> (RaftData term name Entry LogIndex ServerType stateMachineData output
                            ,[(name,Msg)])
handleAppendEntriesReply _me state src term entries result =
    if currentTerm state == term then
      if result then
        let index = maxIndex entries in
          (state {matchIndex =
                   assocSet (matchIndex state) src $ max (assocDefault (matchIndex state) src 0) index
                 ,nextIndex =
                   assocSet (nextIndex state) src (max (getNextIndex state src ) (1 + index) :: LogIndex)}
          ,[])

          else
            (state{nextIndex = assocSet (nextIndex state) src $ pred (getNextIndex state src)}
            ,[])

          else if currentTerm state < term then
            -- follower behind, ignore
            (state,[])
          else -- leader behind, convert to follower
            (advanceCurrentTerm state term, [])

moreUpToDate :: forall a a1.
                      (Ord a, Ord a1) =>
                      a -> a1 -> a -> a1 -> Bool
moreUpToDate t1 i1 t2 i2 = (t1 > t2 ) || ((t1 == t2) && (i1 >= i2))


handleRequestVote :: Eq name
                  => name
                  -> RaftData Term name Entry logIndex ServerType stateMachineData output
                  -> Term
                  -> name
                  -> LogIndex
                  -> Term
                  -> (RaftData Term name Entry logIndex ServerType stateMachineData output
                     ,Msg)
handleRequestVote _me state t candidateId lastLogIndex lastLogTerm =
   if currentTerm state > t
   then
     (state, RequestVoteReply (currentTerm state) False)
   else
     let
       state' = advanceCurrentTerm state t
     in
       if (if isJust (leaderId state') then False else True)
          && moreUpToDate lastLogTerm lastLogIndex (maxTerm (log state')) (maxIndex (log state'))
       then
         case votedFor state' of
           Nothing           -> (state' {votedFor = Just candidateId}
                                ,RequestVoteReply (currentTerm state) True)
           Just candidateId' -> (state', RequestVoteReply (currentTerm state) (candidateId == candidateId'))
       else
         (state', RequestVoteReply (currentTerm state') False)

div2 :: Natural -> Natural
div2 1 = 0
div2 0 = 0
div2 n = 1 +  div2 (n-2)

wonElection :: forall (t :: * -> *) a. Foldable t => t a -> Bool
wonElection votes = 1 + div2 (fromIntegral $ length nodes) <= fromIntegral (length votes)

handleRequestVoteReply :: forall term name entry logIndex stateMachineData output
                       . Ord term
                       => name
                       -> RaftData term name entry logIndex ServerType stateMachineData output
                       -> name
                       -> term
                       -> Bool
                       -> RaftData term name entry logIndex ServerType stateMachineData output
handleRequestVoteReply _me state _src t _voted =
    if t > currentTerm state then (advanceCurrentTerm state t){rdType = Follower}
      else undefined

handleMessage :: forall stateMachineData output
              .  Name
              -> Name
              -> Msg
              -> RaftData Term Name Entry LogIndex ServerType stateMachineData output
              -> (RaftData Term Name Entry LogIndex ServerType stateMachineData output
                 ,[(Name, Msg)])
handleMessage src me m state =
  case m of
    AppendEntries t lid prevLogIndex prevLogTerm entries leaderCommit ->
       let
         (st,r) = handleAppendEntries me state t lid prevLogIndex prevLogTerm entries leaderCommit
       in
         (st, [(src,r)])
    AppendEntriesReply term entries result ->
       handleAppendEntriesReply me state src term entries result
    RequestVote t _candidateId  lastLogIndex lastLogTerm ->
      let
        (st,r) = handleRequestVote me state t src lastLogIndex lastLogTerm
      in
        (st,[(src,r)])
    RequestVoteReply t voteGranted ->
      (handleRequestVoteReply me state src t voteGranted,[])

assoc :: forall  a b. Eq a => [(a, b)] -> a -> Maybe b
assoc = flip lookup

getLastId :: forall term name entry logIndex serverType stateMachineData output
          .  RaftData term name entry logIndex serverType stateMachineData output
          -> Natural
          -> Maybe (Natural, output)
getLastId state = assoc (clientCache state)
-- getLastId state client = assoc (clientCache state) client -- ETA Reduced from this

handler :: forall dataa . Input -> dataa -> (Output,dataa)
handler = error "fill me out/ abstract meeeee "

applyEntry :: forall term name entry logIndex serverType stateMachineData
           .  RaftData term name entry logIndex serverType stateMachineData Output
           -> Entry
           -> ([Output]
              ,RaftData term name entry logIndex serverType stateMachineData Output)
applyEntry st e = let
    (out,d) = handler (eInput e) (stateMachine st)
  in
    ([out]
    ,st {clientCache = assocSet (clientCache st) (eClient e) (unLogIndex $ eId e, out)
        ,stateMachine = d})


catchApplyEntry :: forall term name entry logIndex serverType stateMachineData
                .  RaftData term name entry logIndex serverType stateMachineData Output
                -> Entry
                -> ([Output]
                   ,RaftData term name entry logIndex serverType stateMachineData Output)
catchApplyEntry st e =
  case getLastId st (eClient e) of
    Just (id', o) -> if unLogIndex (eId e) < id'
                    then
                      ([], st)
                    else
                      if unLogIndex (eId e) == id'
                      then
                        ([o], st)
                      else
                        applyEntry st e
    Nothing      -> applyEntry st e

applyEntries :: forall term name entry logIndex serverType stateMachineData
             . Name
             -> RaftData term name entry logIndex serverType stateMachineData Output
             -> [Entry]
             -> ([RaftOutput]
                ,RaftData term name entry logIndex serverType stateMachineData Output)
applyEntries h st entries =
  case entries of
    []     -> ([], st)
    (e:es) -> let
                (out, st') = catchApplyEntry st e
              in
                let
                  out' = if eAt e == h
                         then
                           fmap (\o -> ClientResponse (eClient e) (unLogIndex $ eId e) o) out
                         else
                           []
                in
                  let
                    (out'', state) = applyEntries h st' es
                  in
                    (out' ++ out'', state)

