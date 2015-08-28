{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Network.Consensus.Verified.Raft.Runner where

import Prelude hiding (init)
import Data.Map (Map)
import Data.Set (Set)
import Data.Reflection
import qualified Data.Map as Map
import Control.Applicative(Alternative,(<|>))
import Data.ByteString.Lazy.Char8 (ByteString)

import qualified Network.Consensus.Verified.Raft as Raft
import Network.Consensus.Verified.Raft (
  Res(..)
  ,StateMachine(..)
  ,Name(..)
--  ,Term(..)
--  ,LogIndex(..)
  ,RaftOutput(..)
  ,RaftInput(..)
  ,Msg(..)
  ,RaftData(..)
  ,Name(..))

data InputKV k v = PutKV k v
                 | GetKV k
                 | DelKV k
                 | CASKV k (Maybe v) v
                 | CADKV k v
                 deriving (Eq,Ord,Show)

data OutputKV k v = ResponseKV k (Maybe v) (Maybe v)
  deriving (Eq,Ord,Show)

kvHandler :: forall m k v kv. (Eq v, Monad m) => (kv -> k -> m (Maybe v))
      -> (kv -> k -> v -> m kv )
      -> (kv -> k -> m kv)
      -> StateMachine m (InputKV k v) kv (OutputKV k v,kv)
kvHandler get put del =
  StateMachine $ \ kv cmd ->
    case cmd of
      PutKV k v -> do oldV :: (Maybe v) <- get kv k ;
                      newkv <- put kv k v ;
                      return (ResponseKV k (Just v) oldV,newkv)
      GetKV k -> do v <- get kv k ; return (ResponseKV k v v, kv)
      DelKV k -> do old <- get kv k ; newKV<- del kv k ; return (ResponseKV k Nothing old, newKV)
      CASKV k v v' -> do old <- get kv k ;
                         if old == v
                           then do newKV <- put kv k v' ; return (ResponseKV k (Just v') old, newKV)
                           else return (ResponseKV k old old ,kv)
      CADKV k v -> do old <- get kv k  ;
                      if old == Just v
                        then do newKV <- del kv k ; return (ResponseKV k Nothing old, newKV)
                        else return (ResponseKV k old old,kv)

data Arrangement m state input output message request_id = Arrangement {
  init :: Name -> state
  ,reboot :: state -> state
-- note : handleIO and handleNet
-- both asssume state machines do stateful update
-- afaik, wrt extraction
  ,handleIO :: Name -> input -> state ->  m (Res output state Name message)
  ,handleNet :: Name -> Name -> message -> state -> m (Res output state Name message)
  ,handleTimeout :: Name -> state -> m (Res output state Name message)
  ,setTimeout :: Name -> state -> m Double
  ,deserialize ::  ByteString -> Maybe (request_id,input)
  ,serialize :: output -> (request_id,ByteString)
  ,debug :: Bool
  ,debugRecv :: state -> (Name , message) -> m ()
  ,debugSend :: state -> (Name, message) -> m ()
  ,debugTimeout :: state -> m ()
  }

defaultArrangement :: (Monad m
                      ,Reifies k (Set Name)
                      ,Reifies s (StateMachine m input stateMachineData (output, stateMachineData)))
                   => prox s -> prox k
                   -> Arrangement
                        m
                        (RaftData stateMachineData input output)
                        (RaftInput input)
                        (RaftOutput output)
                        (Msg input)
                        request_id
defaultArrangement ps pk = Arrangement {
  init = Raft.initHandlers
  ,reboot = Raft.reboot
  ,handleIO = Raft.raftInputHandler ps pk
  ,handleNet = Raft.raftNetHandler ps pk
  ,handleTimeout = \nm st -> Raft.handleTimeout pk nm st
  ,setTimeout =  error "setTimeout is an RNG that depends on leadershipness"
  ,deserialize = error "undefined deserialize Arrangement"
  ,serialize = error "undefined serialize Arrangement"
  ,debug = False
  ,debugRecv = error "undefined debugRecv"
  ,debugSend = error "undefined debugSend"
  ,debugTimeout = error "undefined debugTimeout" }

data Env m state out_channel file_descr request_id sockaddr = Env {
  restored_state :: state
  ,snapfile:: String
  ,clog :: out_channel -- this may be spurious type wise
  ,txSocket :: file_descr
  ,rxSocket :: file_descr
--,csocksRead :: m [file_descr] -- think IORef [...]
--,csocksUpdate :: [file_descr] -> m ()
--,outstandingRead :: m (Map request_id file_descr) -- think IORef (Map ...)
--,outstandingUpdate ::  Map request_id file_descr -> m ()
  ,savesRead :: m Int -- think IORef Int
  ,savesWrite :: Int -> m ()
  ,nodes :: m (Map Name sockaddr) -- m [...] to model membership list may change.
                                  -- though verdi proof assumes fixed
  }

data LogStep msg input = LogInput input
                       | LogNet Name msg
                       | LogTimeout
                       deriving (Eq,Ord,Show)

data EnvOps m out_channel state file_descr sockaddr msg request_id input = EnvOps {
-- yieldLogEvents assumes the only newlines are betwee
-- log events
-- yields nothing when reaches end of file
 open :: String -> m file_descr
 ,yieldLogEvents :: file_descr -> m (Maybe (LogStep msg input))
 ,loadSnapShot :: String -> m state
 ,send :: Env m state out_channel file_descr request_id sockaddr -> Name -> msg -> m ()
--  ,receive ::
  }

update_state_from_log_entry :: forall state f output msg input request_id
                             . Functor f
                            => Arrangement f state input output msg request_id
                            -> Name
                            -> state
                            -> LogStep msg input -> f state
update_state_from_log_entry arr nm s op =
    ((\(_,st,_)-> st) . unRes) <$> case op of
                                     LogInput inp -> handleIO arr nm inp s
                                     LogNet src m -> handleNet arr nm src m s
                                     LogTimeout -> handleTimeout arr nm s

get_initial_state :: forall f out_channel file_descr sockaddr state msg input output request_id
                   . Alternative f
                  => EnvOps f out_channel state file_descr sockaddr msg request_id input
                  -> Arrangement f state input output msg request_id
                  -> String
                  -> Name
                  -> f state
get_initial_state eop arr snpfile nm =
  loadSnapShot eop snpfile <|> pure (init arr nm)

restore_from_log :: forall m out_channel state file_descr sockaddr msg input output request_id
                  . Monad m
                 => Arrangement m state input output msg request_id
                 -> EnvOps m out_channel state file_descr sockaddr msg request_id input
                 -> file_descr
                 -> Name
                 -> state
                 -> m state
restore_from_log arr eop fd nm st = go st
  where
    yielder = yieldLogEvents eop fd
    go theState = do
      nextOp <- yielder
      case nextOp of
          Nothing -> return theState
          Just op ->
           do st' <-
                update_state_from_log_entry arr nm st op
              go st'

restore :: forall m state output request_id out_channel file_descr sockaddr msg input
        . (Monad m, Alternative m)
        => Arrangement m state input output msg request_id
        -> EnvOps m out_channel state file_descr sockaddr msg request_id input
        -> String
        -> String
        -> Name
        -> m state
restore arr eop snpfile logfl nm =
   do
    -- this doesn't deal with catching up with
    -- nonlocal update ... i think....
     istate <- get_initial_state eop arr snpfile nm
     logfd <- open eop logfl
     restore_from_log arr eop logfd nm istate




denote :: Monad m
       => Env m state out_channel file_descr request_id sockaddr
       -> Name
       -> m sockaddr
denote env nm =
  do  nds <- nodes env
      maybe
        (fail "bad lookup with denote")
        return
        $  Map.lookup  nm nds

