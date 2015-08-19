{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
--{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE ScopedTypeVariables        #-}
--{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE FlexibleContexts #-}


module Network.Consensus.Verified.Raft where

import Data.Data (Data, Typeable)
import GHC.Generics (Generic)
import Numeric.Natural
import Prelude hiding (log,sin, pred,map)
import Data.Foldable (foldl')
import Data.Maybe (isJust)
import Data.Bytes.Serial
--import qualified Data.Map as Map
--import Data.Map (Map)
import Data.Profunctor
import qualified Control.Category as CC
import Data.Reflection
import qualified Data.Set as Set
import Data.Set (Set)

map :: Functor f => (a -> b) -> f a -> f b
map = fmap

data RaftData term name  logIndex stateMachineData input output =
    RaftData {
    -- persistent
       currentTerm        :: term
      ,votedFor           :: Maybe name
      ,leaderId           :: Maybe name
      ,log                :: [Entry input]
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
      ,rdType             :: ServerType
    -- client request state
      ,clientCache        :: [(ECLIENT,(EID,output))]
    -- ghost variables ---- but do we care?
      ,electoralVictories :: [(term,[name],[Entry input])]
  } deriving (Read,Show,Typeable,Data,Generic)

instance (Serial term , Serial name,Serial logIndex,Serial stateMachine
          , Serial input,Serial output)
    => Serial (RaftData term name logIndex stateMachine input output)

newtype  Res output state name msg = Res {unRes :: ([output],state,[(name,msg)])}
  deriving (Eq,Ord,Show)

-- | StateMachine is  ... a state machine
-- in this code base it'd used as @StateMachine state input (output,state)@
-- where state == stateMachineData
data StateMachine m   message stateIn stateOut  =
    StateMachine   {
      stepSM :: stateIn -> message -> m  stateOut
  }

instance Functor m => Profunctor (StateMachine m  message) where
   dimap fin fout (StateMachine step) =
        StateMachine  (\ sin msg ->   fmap  fout $ step  (fin   sin) msg  )


instance Functor m => Functor (StateMachine m  message stateIn) where
  fmap f (StateMachine step) =
          StateMachine  (\ sin msg -> fmap  f $ step sin msg )


instance (Monad m) => CC.Category (StateMachine m  message) where
    id = StateMachine ( \ x _ ->  pure x)
    (.)  (StateMachine step2) (StateMachine step1) =
        StateMachine  (\ sin msg -> do  r <- step1 sin msg ; step2 r msg)



newtype Term = Term { unTerm :: OrphNatural }
    deriving (Read,Eq,Show,Ord,Num,Data,Typeable,Generic)
instance Serial Term

-- | This exists only as a work around to byte's lack of
-- serial instance for Natural
-- which should be easy to fix
newtype OrphNatural = OrphNatural { unOrphNatural :: Natural }
   deriving (Eq, Show,Ord,Enum,Num,Integral,Generic,Data,Real,Read)
instance Serial OrphNatural where
    serialize (OrphNatural n)= serialize $ show n
    deserialize = fmap read  deserialize

newtype LogIndex = LogIndex { unLogIndex :: OrphNatural }
    deriving (Read,Eq,Show,Ord,Num,Data,Typeable,Generic)
instance Serial LogIndex

newtype Name = Name { unName :: OrphNatural  }
    deriving (Read,Eq,Show,Ord,Num,Data,Typeable,Generic)
instance Serial Name
--data Input = Input deriving (Eq,Ord,Show)
--data Output = Output deriving (Eq,Ord,Show)

--- the verdi raft doesn't deal with changing membership
--nodes ::  [Name]
--nodes = undefined

--- the verdi raft doesn't deal with this, which we'll need to wrap in MonadIO or whatever
initState :: forall stateMachineData . stateMachineData
initState = undefined

--- VerdiRaft doesn't distinquish these but all NATS are not the same!
newtype ECLIENT = ECLIENT { unECLIENT :: OrphNatural }
    deriving (Read, Eq, Show, Ord, Num, Data, Typeable, Generic)
instance Serial ECLIENT
newtype EID = EID { unEID :: OrphNatural }
    deriving (Read, Eq, Show, Ord, Num, Data, Typeable, Generic)
instance Serial EID

data Entry input = Entry {
   eAt     :: Name
  ,eClient :: ECLIENT -- should this be Name?
  ,eId     :: EID
  ,eIndex  :: LogIndex
  ,eTerm   :: Term
  ,eInput  :: input
  } deriving (Eq,Ord,Show,Read,Data,Generic)
instance Serial input => Serial (Entry input)

data Msg input= RequestVote Term Name LogIndex Term
          | RequestVoteReply Term Bool
          | AppendEntries Term Name LogIndex Term [Entry input ] LogIndex
          | AppendEntriesReply Term [Entry  input] Bool
          deriving (Eq,Read,Ord,Show,Generic,Data)
instance Serial input => Serial (Msg input)

data RaftInput input = Timeout
               | ClientRequest ECLIENT EID input
               deriving (Eq,Read,Ord,Show,Generic,Data )
instance Serial input => Serial (RaftInput input)



data RaftOutput output = NotLeader ECLIENT EID
                | ClientResponse ECLIENT EID output
                deriving (Eq,Ord,Read,Show,Generic,Data)
instance Serial output => Serial (RaftOutput output)

data ServerType = Follower
                | Candidate
                | Leader
                deriving (Eq,Ord,Read,Show,Generic,Data)
instance Serial ServerType

findAtIndex :: [Entry input] -> LogIndex -> Maybe (Entry input)
findAtIndex [] _ = Nothing
findAtIndex (e:es) i
  | eIndex e ==  i = Just e
  | eIndex e < i = Nothing
  | otherwise = findAtIndex es i

findGtIndex :: [Entry input] -> LogIndex -> [Entry input]
findGtIndex [] _i = []
findGtIndex (e:es) i
  | eIndex e > i = e : findGtIndex es i
  | otherwise    = []

removeAfterIndex :: [Entry input] -> LogIndex  -> [Entry input]
removeAfterIndex [] _ = []
removeAfterIndex (e:es) i
  | eIndex e <= i = e : es
  | otherwise = removeAfterIndex es i

maxIndex :: [Entry input] -> LogIndex
maxIndex [] = LogIndex 0
maxIndex (e:_es) = eIndex e

maxTerm :: [Entry input] -> Term
maxTerm [] =  0
maxTerm (e:_es) = eTerm e

advanceCurrentTerm :: forall term name  logIndex stateMachineData output input
                    . Ord term
                   => RaftData term name  logIndex  stateMachineData input output
                   -> term
                   -> RaftData term name  logIndex  stateMachineData input output
advanceCurrentTerm state newTerm
      | newTerm > currentTerm state =
              state {currentTerm = newTerm
                    ,votedFor = Nothing
                    ,rdType = Follower
                    ,leaderId = Nothing
                    }
      | otherwise = state

getNextIndex :: forall term name stateMachineData input output
              . Eq name
             => RaftData term name  LogIndex stateMachineData input output
             -> name
             -> LogIndex
getNextIndex state h = assocDefault (nextIndex state) h (maxIndex (log state))

tryToBecomeLeader :: Reifies k (Set Name)
                  => prox k
                  -> Name
                  -> RaftData Term Name  logIndex  stateMachineData input output
                  -> ([RaftOutput output]
                     ,RaftData Term Name  logIndex  stateMachineData input output
                     ,[(Name,Msg iput)])
tryToBecomeLeader pk me state =
    ([]
    ,state {rdType = Candidate
           ,votedFor = Just me
           ,votesReceived = [me]
           ,currentTerm = t}
    ,map (\node -> (node, RequestVote t me
                            (maxIndex (log state))
                            (maxTerm (log state)))
         ) $ filter (\h -> h == me) $ Set.toList $ reflect pk  )
        where
          t :: Term
          t = 1 + currentTerm state

notEmpty :: [a] -> Bool
notEmpty [] = False
notEmpty (_:_) = True

haveNewEntries :: forall term name logIndex stateMachineData input output
                . RaftData term name  logIndex stateMachineData input output
               -> [Entry input]
               -> Bool
haveNewEntries state entries =
  notEmpty entries && case findAtIndex (log state) (maxIndex entries) of
                        Just e -> maxTerm entries /= eTerm e
                        Nothing -> False

handleAppendEntries :: Name
                    -> RaftData Term Name  LogIndex  stateMachineData input  output
                    -> Term
                    -> Name
                    -> LogIndex
                    -> Term
                    -> [Entry input]
                    -> LogIndex
                    -> (RaftData Term Name  LogIndex  stateMachineData input output
                       ,Msg input)
handleAppendEntries _me state t mleaderId prevLogIndex prevLogTerm entries leaderCommit
    | currentTerm state > t  =   (state, AppendEntriesReply (currentTerm state) entries False)
    | haveNewEntries state entries =
        ((advanceCurrentTerm state t) {
              log      = entries
             ,commitIndex = max (commitIndex state) (min leaderCommit (maxIndex entries ))
             ,rdType      = Follower
             ,leaderId    = Just mleaderId }
        ,AppendEntriesReply t entries True)
    | otherwise = case findAtIndex (log state) prevLogIndex of
      Nothing -> (state, AppendEntriesReply (currentTerm state) entries False)
      Just e | prevLogTerm /= eTerm e ->(state, AppendEntriesReply (currentTerm state) entries False)
             |  haveNewEntries  state entries ->  let
                log' = removeAfterIndex (log state) prevLogIndex
                log'' = entries ++ log'
                 in
                  ((advanceCurrentTerm state t) {
                         log         = log''
                        ,commitIndex = max (commitIndex state) (min leaderCommit (maxIndex log''))
                        ,rdType      = Follower
                        ,leaderId    = Just mleaderId}
                  ,AppendEntriesReply t entries True)
            | otherwise ->
               ((advanceCurrentTerm state t) {
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

pred :: (Num a, Ord a) => a -> a
pred n | n <= 0 = 0
       | otherwise = n -1

handleAppendEntriesReply :: forall t term name stateMachineData input output
                         .  (Ord term, Eq name)
                         => t
                         -> RaftData term name  LogIndex  stateMachineData input output
                         -> name
                         -> term
                         -> [Entry input]
                         -> Bool
                         -> (RaftData term name  LogIndex  stateMachineData input output
                            ,[(name,Msg input)])
handleAppendEntriesReply _me state src term entries result
    |  currentTerm state == term  =
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

     | currentTerm state < term =
            -- follower behind, ignore
            (state,[])
     | otherwise = (advanceCurrentTerm state term, [])

moreUpToDate :: forall a a1.
                      (Ord a, Ord a1) =>
                      a -> a1 -> a -> a1 -> Bool
moreUpToDate t1 i1 t2 i2 = (t1 > t2 ) || ((t1 == t2) && (i1 >= i2))


handleRequestVote :: Eq name
                  => name
                  -> RaftData Term name  logIndex  stateMachineData  input output
                  -> Term
                  -> name
                  -> LogIndex
                  -> Term
                  -> (RaftData Term name  logIndex  stateMachineData input output
                     ,Msg input)
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

wonElection :: forall prox k t  a. (Reifies k (Set Name),Foldable t) => prox k -> t a -> Bool
wonElection pk votes = 1 + div2 (fromIntegral $ Set.size $ reflect pk  ) <= fromIntegral (length votes)

handleRequestVoteReply :: forall term name logIndex stateMachineData input output
                       . Ord term
                       => name
                       -> RaftData term name logIndex  stateMachineData input output
                       -> name
                       -> term
                       -> Bool
                       -> RaftData term name logIndex  stateMachineData input output
handleRequestVoteReply _me state _src t _voted =
    if t > currentTerm state then (advanceCurrentTerm state t){rdType = Follower}
      else undefined

handleMessage :: forall stateMachineData output input
              .  Name
              -> Name
              -> Msg input
              -> RaftData Term Name  LogIndex  stateMachineData input output
              -> (RaftData Term Name LogIndex  stateMachineData input output
                 ,[(Name, Msg input)])
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

getLastId :: forall  term name   stateMachineData input output
          .  RaftData term name  LogIndex stateMachineData input  output
          -> ECLIENT
          -> Maybe (EID, output)
getLastId state client = assoc (clientCache state) client

handler :: forall s m input output state prox  .  (Reifies   s (StateMachine m input state (output, state))) =>  prox s -> input  ->  state -> m (output,state)
handler p  input state = ( stepSM $ reflect p ) state input

applyEntry :: forall term name s  output input stateMachineData m prox
           . (Monad m,   (Reifies   s (StateMachine m input stateMachineData (output, stateMachineData))))
           => prox s ->   RaftData term name  LogIndex stateMachineData input output
           -> Entry input
           -> m ([output]
              ,RaftData term name  LogIndex stateMachineData input output)
applyEntry p  st e = do
    (out,d) <- handler  p (eInput e) (stateMachine st)
    return ([out]
            ,st {clientCache = assocSet (clientCache st) (eClient e) (eId e, out)
            ,stateMachine = d})


catchApplyEntry :: forall term name   stateMachineData input output m p s
                .  (Monad m, (Reifies   s (StateMachine m input stateMachineData (output, stateMachineData))))
                 => p s
                -> RaftData term name  LogIndex stateMachineData input output
                -> Entry input
                ->  m ([output]
                   ,RaftData term name  LogIndex stateMachineData input output)
catchApplyEntry p  st e =
  case getLastId st (eClient e) of
    Just (id', o) |  eId e < id' ->   return  ([], st)
                  |  eId e == id' ->  return  ([o], st)
                  | otherwise ->   applyEntry p  st e
    Nothing      -> applyEntry p st e

applyEntries :: forall term name   stateMachineData input output m p s
             .  (Monad m, (Reifies   s (StateMachine m input stateMachineData (output, stateMachineData))))
             => p s
             -> Name
             -> RaftData term name  LogIndex stateMachineData input output
             -> [Entry input]
             -> m  ([RaftOutput output]
                ,RaftData term name  LogIndex stateMachineData input output)
applyEntries p h st entries =
  case entries of
    []     -> return  ([], st)
    (e:es) -> do
                (out, st') <-  catchApplyEntry p  st e
                let out' = if eAt e == h
                         then
                           fmap (\o -> ClientResponse (eClient e) (eId e) o) out
                         else
                           []

                (out'', state)<- applyEntries p h st' es
                return  (out' ++ out'', state)

doGenericServer :: forall term name stateMachineData input output p s m
                . (Monad m, (Reifies   s (StateMachine m input stateMachineData (output, stateMachineData))))
                => p s
                -> Name
                -> RaftData term name LogIndex stateMachineData input output
                -> m  ([RaftOutput output]
                   ,RaftData term name LogIndex stateMachineData input output
                   ,[(Name,Msg input)])
doGenericServer p  h state =
    do  (out, state') <- applyEntries p  h state
                         (reverse
                         $ filter (\x ->  lastApplied state <  eIndex x
                                      && eIndex x <= commitIndex state)
                         $ findGtIndex (log state) (lastApplied state))
        return (out , state'{lastApplied= if commitIndex state' > lastApplied state'  then commitIndex state else lastApplied state}, [])

replicaMessage :: forall name stateMachineData input output
               .  Eq name
               => RaftData Term name  LogIndex stateMachineData input output
               -> Name
               -> name
               -> (name, Msg input )
replicaMessage state me host =
  let prevIndex = pred (getNextIndex state host) in
   let prevTerm = case findAtIndex (log state) prevIndex of
                    Just e -> eTerm e
                    Nothing -> 0
    in
      let newEntries = findGtIndex  (log state) prevIndex in
         (host, AppendEntries (currentTerm state) me prevIndex prevTerm newEntries (commitIndex state))

haveQuorum :: forall k prox term  stateMachineData input  output
           . Reifies k (Set Name)
           =>prox k
            -> RaftData term Name  LogIndex stateMachineData input output
           -> Name
           -> LogIndex
           -> Bool
haveQuorum pk state  _me n   =
    div2 (fromIntegral $ Set.size $ reflect pk)
    < fromIntegral (length $
               filter (\ h -> n <= assocDefault (matchIndex state) h 0) $
                 Set.toList $ reflect pk)

advanceCommitIndex :: forall stateMachineData input  output prox k
                   .  Reifies k (Set Name)
                   =>  prox k
                   -> RaftData Term Name  LogIndex stateMachineData input output
                   -> Name
                   -> RaftData Term Name  LogIndex stateMachineData input output
advanceCommitIndex pk state me =
   let entriesToCommit = filter
             (\ e -> (currentTerm state == eTerm e)
                     && commitIndex state < eIndex e
                     && haveQuorum pk state me (eIndex e))
             (findGtIndex (log state) (commitIndex state))
     in
        state{commitIndex=(\a c b -> foldl' a b c) max (map eIndex entriesToCommit) (commitIndex state)}

doLeader :: forall stateMachineData output input prox k
         .  Reifies k (Set Name)
         => prox k
         -> RaftData Term Name  LogIndex  stateMachineData input output
         -> Name
         -> ([RaftOutput output]
            ,RaftData Term Name  LogIndex  stateMachineData input output
            ,[(Name, Msg input)])
doLeader pk  state me =
    case rdType state of
      Leader -> let
          state' = advanceCommitIndex pk  state me
        in
          if shouldSend state'
          then
              let
                state'' = state'{shouldSend = False}
              in
                let
                  replicaMessages = map (replicaMessage state'' me)
                                        (filter
                                         (\ h ->  me /= h )  $ Set.toList $ reflect pk )
                in
                   ([], state'', replicaMessages)
          else
            ([], state',[])
      Candidate  -> ([], state,[])
      Follower -> ([],state,[])

raftNetHandler :: forall stateMachineData input output m p s k
               . (Monad m
                ,Reifies k (Set Name)
                ,Reifies   s (StateMachine m input stateMachineData (output, stateMachineData)))
               => p s
               -> p k
               -> Name
               -> Name
               -> Msg input
               -> RaftData Term Name  LogIndex stateMachineData input output
               -> m  (Res
                           (RaftOutput output)
                           (RaftData Term Name LogIndex stateMachineData input output)
                           Name
                           (Msg input))
raftNetHandler ps pk   me src m state =
  let
    (state', pkts) = handleMessage src me m state
  in
    do
      (genericeOut, state'', genericPkts) <-  doGenericServer ps  me state'
      let
        (leaderOut, state''', leaderPkts) = doLeader pk  state'' me
      return $ Res (genericeOut ++ leaderOut
              ,state'''
              ,pkts ++ genericPkts ++ leaderPkts)

handleClientRequest :: forall stateMachineData input  output
                    .  Name
                    -> RaftData Term Name  LogIndex  stateMachineData input output
                    -> ECLIENT
                    -> EID
                    -> input
                    -> Res
                         (RaftOutput output)
                         (RaftData Term Name LogIndex stateMachineData input output)
                         Name
                         (Msg input)
handleClientRequest me state client id' c =
  Res $ case rdType state of
    Leader -> let
                index = 1 + maxIndex (log state)
              in
                ([]
                ,state{log = Entry me client id' index (currentTerm state) c : log state
                      ,matchIndex = assocSet (matchIndex state) me index
                      ,shouldSend = True}
                ,[])
    Follower -> ([NotLeader client id'], state, [])
    Candidate -> ([NotLeader client id'], state, [])

handleTimeout :: forall  stateMachineData output input  p k
              . Reifies k (Set Name)
              => p k
              -> Name
              -> RaftData Term Name  LogIndex stateMachineData input output
              -> Res
                     (RaftOutput output)
                     (RaftData Term Name LogIndex stateMachineData input output)
                     Name
                     (Msg input)
handleTimeout  pk me state =
  Res $ case rdType state of
    Leader -> ([], state{shouldSend=True}, []) -- We auto-heartbeat elsewhere
    Candidate -> tryToBecomeLeader pk  me state
    Follower -> tryToBecomeLeader pk  me state

handleInput :: forall stateMachineData output input p k
            . Reifies k (Set Name)
            => p k
            ->  Name
            -> RaftInput input
            -> RaftData Term Name LogIndex stateMachineData input output
            -> Res
                     (RaftOutput output)
                     (RaftData Term Name LogIndex stateMachineData input output)
                     Name
                     (Msg input)
handleInput pk me inp state =
    case inp of
    ClientRequest client id' c -> handleClientRequest me state client id' c
    Timeout -> handleTimeout pk  me state

raftInputHandler :: forall stateMachineData input output p s k m
                 . (Monad m
                  ,Reifies k  (Set Name)
                  ,Reifies s (StateMachine m input stateMachineData (output, stateMachineData)))
                 => p s
                 -> p k
                 -> Name
                 -> RaftInput input
                 -> RaftData Term Name  LogIndex  stateMachineData input output
                 -> m (Res
                           (RaftOutput output)
                           (RaftData Term Name LogIndex stateMachineData input output)
                           Name
                           (Msg input)
                           )
raftInputHandler p pk  me inp state =
    let
      (handlerOut, state', pkts) = unRes $ handleInput pk  me inp state
    in
      do (genericOut, state'', genericPkts) <-  doGenericServer p  me state'
         let
            (leaderOut, state''', leaderPkts) = doLeader pk state'' me
         return $ Res
              (handlerOut ++ genericOut ++ leaderOut
              ,state'''
              ,pkts ++ genericPkts ++ leaderPkts)

reboot :: forall term name  logIndex  stateMachineData input output
       .  RaftData term name  logIndex  stateMachineData input output
       -> RaftData term name  logIndex  stateMachineData input output
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

initHandlers :: forall name stateMachineData input output
             .  name
             -> RaftData Term name  LogIndex  stateMachineData input output
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
