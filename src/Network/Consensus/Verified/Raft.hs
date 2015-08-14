{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE ScopedTypeVariables        #-}

module Network.Consensus.Verified.Raft where

import Data.Data (Data, Typeable)
import GHC.Generics (Generic)
import Numeric.Natural
import Prelude hiding (log, pred)
import Data.Foldable (foldl')
import Data.Maybe (isJust)

data RaftData term name entry logIndex serverType stateMachineData output =
    RaftData {
    -- persistent
       currentTerm        :: term
      ,votedFor           :: Maybe name
      ,leaderId           :: Maybe name
      ,log                :: [entry]
    -- volatile
      ,commitIndex        :: logIndex
      ,lastApplied        :: logIndex
      ,stateMachine       :: stateMachineData
    -- leader state
      ,nextIndex          :: [(name,logIndex)]
      ,matchIndex         :: [(name,logIndex)]
      ,shouldSend         :: Bool
    -- candidate state
      ,votesReceived      :: [name]
    -- whoami
      ,rdType             :: serverType
    -- client request state
      ,clientCache        :: [(ECLIENT,(EID,output))]
    -- ghost variables ---- but do we care?
      ,electoralVictories :: [(term,[name],[entry])]
  } deriving (Read,Show,Typeable,Data,Generic)

newtype Term = Term { unTerm :: Natural }
    deriving (Read,Eq,Show,Ord,Num,Data,Typeable,Generic)

newtype LogIndex = LogIndex { unLogIndex :: Natural }
    deriving (Read,Eq,Show,Ord,Num,Data,Typeable,Generic)

newtype Name = Name { unName :: Natural  }
    deriving (Read,Eq,Show,Ord,Num,Data,Typeable,Generic)

data Input = Input deriving (Eq,Ord,Show)
data Output = Output deriving (Eq,Ord,Show)

--- the verdi raft doesn't deal with changing membership
nodes ::  [Name]
nodes = undefined

--- the verdi raft doesn't deal with this, which we'll need to wrap in MonadIO or whatever
initState :: forall stateMachineData . stateMachineData
initState = undefined

--- VerdiRaft doesn't distiquish these but all NATS are not the same!
newtype ECLIENT = ECLIENT { unECLIENT :: Natural }
    deriving (Read, Eq, Show, Ord, Num, Data, Typeable, Generic)
newtype EID = EID { unEID :: Natural }
    deriving (Read, Eq, Show, Ord, Num, Data, Typeable, Generic)

data Entry = Entry {
   eAt     :: Name
  ,eClient :: ECLIENT -- should this be Name?
  ,eId     :: EID
  ,eIndex  :: LogIndex
  ,eTerm   :: Term
  ,eInput  :: Input
  } deriving (Eq,Ord,Show )

data Msg = RequestVote Term Name LogIndex Term
          | RequestVoteReply Term Bool
          | AppendEntries Term Name LogIndex Term [Entry] LogIndex
          | AppendEntriesReply Term [Entry] Bool
          deriving (Eq,Ord,Show)

data RaftInput = Timeout
               | ClientRequest ECLIENT EID Input
               deriving (Eq,Ord,Show)

data RaftOutput = NotLeader ECLIENT EID
                | ClientResponse ECLIENT EID Output
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
      | newTerm > currentTerm state =
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
                  -> ([RaftOutput]
                     ,RaftData Term Name Entry logIndex ServerType stateMachineData output
                     ,[(Name,Msg)])
tryToBecomeLeader me state =
    ([]
    ,state {rdType = Candidate
           ,votedFor = Just me
           ,votesReceived = [me]
           ,currentTerm = t}
    ,map (\node -> (node, RequestVote t me
                            (maxIndex (log state))
                            (maxTerm (log state)))
         ) $ filter (\h -> h == me) nodes)
        where
          t :: Term
          t = 1 + currentTerm state

notEmpty :: [a] -> Bool
notEmpty [] = False
notEmpty (_:_) = True

haveNewEntries :: forall term name logIndex serverType stateMachineData output
                . RaftData term name Entry logIndex serverType stateMachineData output
               -> [Entry]
               -> Bool
haveNewEntries state entries =
  notEmpty entries && case findAtIndex (log state) (maxIndex entries) of
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
              log      = entries
             ,commitIndex = max (commitIndex state) (min leaderCommit (maxIndex entries ))
             ,rdType      = Follower
             ,leaderId    = Just mleaderId }
        ,AppendEntriesReply t entries True)
    else case findAtIndex (log state) prevLogIndex of
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

getLastId :: forall  term name entry  serverType stateMachineData output
          .  RaftData term name entry LogIndex serverType stateMachineData output
          -> ECLIENT
          -> Maybe (EID, output)
getLastId state client = assoc (clientCache state) client

handler :: forall dataa . Input -> dataa -> (Output,dataa)
handler = error "fill me out/ abstract meeeee "

applyEntry :: forall term name entry  serverType stateMachineData
           .  RaftData term name entry LogIndex serverType stateMachineData Output
           -> Entry
           -> ([Output]
              ,RaftData term name entry LogIndex serverType stateMachineData Output)
applyEntry st e = let
    (out,d) = handler (eInput e) (stateMachine st)
  in
    ([out]
    ,st {clientCache = assocSet (clientCache st) (eClient e) (eId e, out)
        ,stateMachine = d})


catchApplyEntry :: forall term name entry  serverType stateMachineData
                .  RaftData term name entry LogIndex serverType stateMachineData Output
                -> Entry
                -> ([Output]
                   ,RaftData term name entry LogIndex serverType stateMachineData Output)
catchApplyEntry st e =
  case getLastId st (eClient e) of
    Just (id', o) -> if  (eId e) < id'
                    then
                      ([], st)
                    else
                      if  (eId e) == id'
                      then
                        ([o], st)
                      else
                        applyEntry st e
    Nothing      -> applyEntry st e

applyEntries :: forall term name entry  serverType stateMachineData
             . Name
             -> RaftData term name entry LogIndex serverType stateMachineData Output
             -> [Entry]
             -> ([RaftOutput]
                ,RaftData term name entry LogIndex serverType stateMachineData Output)
applyEntries h st entries =
  case entries of
    []     -> ([], st)
    (e:es) -> let
                (out, st') = catchApplyEntry st e
              in
                let
                  out' = if eAt e == h
                         then
                           fmap (\o -> ClientResponse (eClient e) (eId e) o) out
                         else
                           []
                in
                  let
                    (out'', state) = applyEntries h st' es
                  in
                    (out' ++ out'', state)

doGenericServer :: forall term name serverType stateMachineData
                .  Name
                -> RaftData term name Entry LogIndex serverType stateMachineData Output
                -> ([RaftOutput]
                   ,RaftData term name Entry LogIndex serverType stateMachineData Output
                   ,[(Name,Msg)])
doGenericServer h state =
    let (out, state') = applyEntries h state
                      (reverse
                         $ filter (\x ->  lastApplied state <  eIndex x
                                      && eIndex x <= commitIndex state)
                         $ findGtIndex (log state) (lastApplied state))
     in
          (out , state'{lastApplied= if commitIndex state' > lastApplied state'  then commitIndex state else lastApplied state}, [])

replicaMessage :: forall name serverType stateMachineData output
               .  Eq name
               => RaftData Term name Entry LogIndex serverType stateMachineData output
               -> Name
               -> name
               -> (name, Msg)
replicaMessage state me host =
  let prevIndex = pred (getNextIndex state host) in
   let prevTerm = case findAtIndex (log state) prevIndex of
                    Just e -> eTerm e
                    Nothing -> 0
    in
      let newEntries = findGtIndex  (log state) prevIndex in
         (host, AppendEntries (currentTerm state) me prevIndex prevTerm newEntries (commitIndex state))

haveQuorum :: forall term entry serverType stateMachineData output
           .  RaftData term Name entry LogIndex serverType stateMachineData output
           -> Name
           -> LogIndex
           -> Bool
haveQuorum state  _me n   =
   div2 (fromIntegral $ length nodes)
        < (fromIntegral $ length $ filter (\h -> n <= assocDefault (matchIndex state) h 0 ) nodes)

advanceCommitIndex :: forall serverType stateMachineData output
                   .  RaftData Term Name Entry LogIndex serverType stateMachineData output
                   -> Name
                   -> RaftData Term Name Entry LogIndex serverType stateMachineData output
advanceCommitIndex state me =
   let entriesToCommit = filter
             (\ e -> (currentTerm state == eTerm e)
                     && (commitIndex state < eIndex e)
                     && (haveQuorum state me (eIndex e)))
             (findGtIndex (log state) (commitIndex state))
     in
        state{commitIndex=(\a c b -> foldl' a b c) max (map eIndex entriesToCommit) (commitIndex state)}

doLeader :: forall stateMachineData output
         .  RaftData Term Name Entry LogIndex ServerType stateMachineData output
         -> Name
         -> ([RaftOutput]
            ,RaftData Term Name Entry LogIndex ServerType stateMachineData output
            ,[(Name, Msg)])
doLeader state me =
    case rdType state of
      Leader -> let
          state' = advanceCommitIndex state me
        in
          if shouldSend state'
          then
              let
                state'' = state'{shouldSend = False}
              in
                let
                  replicaMessages = map (replicaMessage state'' me)
                                        (filter
                                         (\ h -> if me == h then False else True) nodes)
                in
                   ([], state'', replicaMessages)
          else
            ([], state',[])
      Candidate  -> ([], state,[])
      Follower -> ([],state,[])

raftNetHandler :: forall stateMachineData
               . Name
               -> Name
               -> Msg
               -> RaftData Term Name Entry LogIndex ServerType stateMachineData Output
               -> ([RaftOutput]
                  ,RaftData Term Name Entry LogIndex ServerType stateMachineData Output
                  ,[(Name, Msg)])
raftNetHandler me src m state =
  let
    (state', pkts) = handleMessage src me m state
  in
    let
      (genericeOut, state'', genericPkts) = doGenericServer me state'
    in
      let
        (leaderOut, state''', leaderPkts) = doLeader state'' me
      in
        (genericeOut ++ leaderOut
        ,state'''
        ,pkts ++ genericPkts ++ leaderPkts)

handleClientRequest :: forall stateMachineData output
                    .  Name
                    -> RaftData Term Name Entry LogIndex ServerType stateMachineData output
                    -> ECLIENT
                    -> EID
                    -> Input
                    -> ([RaftOutput]
                        ,RaftData Term Name Entry LogIndex ServerType stateMachineData output
                        ,[(Name, Msg)])
handleClientRequest me state client id' c =
  case rdType state of
    Leader -> let
                index = 1 + (maxIndex (log state))
              in
                ([]
                ,state{log = Entry me client id' index (currentTerm state) c : log state
                      ,matchIndex = assocSet (matchIndex state) me index
                      ,shouldSend = True}
                ,[])
    Follower -> ([NotLeader client id'], state, [])
    Candidate -> ([NotLeader client id'], state, [])

handleTimeout :: forall logIndex stateMachineData output
              .  Name
              -> RaftData Term Name Entry logIndex ServerType stateMachineData output
              -> ([RaftOutput]
                 ,RaftData Term Name Entry logIndex ServerType stateMachineData output
                 ,[(Name, Msg)])
handleTimeout me state =
  case rdType state of
    Leader -> ([], state{shouldSend=True}, []) -- We auto-heartbeat elsewhere
    Candidate -> tryToBecomeLeader me state
    Follower -> tryToBecomeLeader me state

handleInput :: forall stateMachineData output
            .  Name
            -> RaftInput
            -> RaftData Term Name Entry LogIndex ServerType stateMachineData output
            -> ([RaftOutput]
               ,RaftData Term Name Entry LogIndex ServerType stateMachineData output
               ,[(Name, Msg)])
handleInput me inp state =
  case inp of
    ClientRequest client id' c -> handleClientRequest me state client id' c
    Timeout -> handleTimeout me state

raftInputHandler :: forall stateMachineData
                 . Name
                 -> RaftInput
                 -> RaftData Term Name Entry LogIndex ServerType stateMachineData Output
                 -> ([RaftOutput]
                    ,RaftData Term Name Entry LogIndex ServerType stateMachineData Output
                    ,[(Name, Msg)])
raftInputHandler me inp state =
    let
      (handlerOut, state', pkts) = handleInput me inp state
    in
      let
        (genericOut, state'', genericPkts) = doGenericServer me state'
      in
        let
          (leaderOut, state''', leaderPkts) = doLeader state'' me
        in
          (handlerOut ++ genericOut ++ leaderOut
          ,state'''
          ,pkts ++ genericPkts ++ leaderPkts)

reboot :: forall term name entry logIndex  stateMachineData output
       .  RaftData term name entry logIndex ServerType stateMachineData output
       -> RaftData term name entry logIndex ServerType stateMachineData output
reboot state =
    RaftData (currentTerm state)
             (votedFor state)
             (leaderId state)
             (log state)
             (commitIndex state)
             (lastApplied state)
             (stateMachine state)
             []
             []
             False
             []
             Follower
             (clientCache state)
             (electoralVictories state)

initHandlers :: forall name entry  stateMachineData output
             .  name
             -> RaftData Term name entry LogIndex ServerType stateMachineData output
initHandlers _name =
    RaftData 0
             Nothing
             Nothing
             []
             0
             0
             initState
             []
             []
             False
             []
             Follower
             []
             []