{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Network.Consensus.Verified.Raft.Runner where

import Prelude hiding (init )
import qualified Network.Consensus.Verified.Raft as Raft
import Network.Consensus.Verified.Raft (Res(..)
        ,StateMachine(..)
        ,Name(..)
        ,Term(..)
        ,LogIndex(..)
        ,RaftOutput(..)
        ,RaftInput(..)
        ,Msg(..)
        ,RaftData(..))
import Data.Map (Map)
import Data.Set (Set)
import Data.Reflection
import qualified Data.Map as Map
import Control.Applicative(Alternative,(<|>))

data Arrangement m name state input output message request_id =
  Arrangement {
        init :: name -> state
        ,reboot :: state -> state
        -- note : handleIO and handleNet
        -- both asssume state machines do stateful update
        -- afaik, wrt extraction
        ,handleIO :: name -> input -> state ->  m (Res output state name message)
        ,handleNet :: name -> name -> message -> state -> m (Res output state name message)
        ,handleTimeout :: name -> state -> m (Res output state name message)
        ,setTimeout :: name -> state ->  Res output state name message
        ,deserialize ::  String -> Maybe (request_id,input)
        ,serialize :: output -> (request_id,String)
        ,debug :: Bool
        ,debugRecv :: state -> (name , message) -> m ()
        ,debugSend :: state -> (name, message) -> m ()
        ,debugTimeout :: state -> m ()

  }

defaultArrangement :: (Monad m
                  ,Reifies k  (Set Name)
                  ,Reifies s (StateMachine m input stateMachineData (output, stateMachineData)))
              => prox s -> prox k
              -> Arrangement
                   m
                   Name
                   (RaftData Term Name LogIndex stateMachineData input output)
                   (RaftInput input)
                   (RaftOutput output)
                   (Msg input)
                   request_id
defaultArrangement ps pk  = Arrangement {
    init = Raft.initHandlers
    ,reboot = Raft.reboot
    ,handleIO = Raft.raftInputHandler ps pk
    ,handleNet = Raft.raftNetHandler ps pk
    ,handleTimeout = \nm st -> return $ Raft.handleTimeout pk nm st
    ,setTimeout = Raft.handleTimeout pk
    ,deserialize = error "undefined deserialize Arrangement"
    ,serialize = error "undefined serialize Arrangement"
    ,debug = False
    ,debugRecv = error "undefined debugRecv"
    ,debugSend = error "undefined debugSend"
    ,debugTimeout = error "undefined debugTimeout"
  }




data Env m  state out_channel file_descr request_id sockaddr name = Env {
    restored_state :: state
    ,snapfile:: String
    ,clog :: out_channel
    ,usock :: file_descr
    ,isock :: file_descr
    ,csocksRead :: m [file_descr] -- think IORef [...]
    ,csocksUpdate :: [file_descr] -> m ()
    ,outstandingRead :: m (Map request_id file_descr) -- think IORef (Map ...)
    ,outstandingUpdate ::  Map request_id file_descr -> m ()
    ,savesRead :: m Int -- think IORef Int
    ,savesWrite :: Int -> m ()
    ,nodes :: m (Map name sockaddr) -- m [...] to model membership list may change.
                                  -- though verdi proof assumes fixed

  }


data LogStep name msg input = LogInput input | LogNet name msg  | LogTimeout
  deriving (Eq,Ord,Show)


data EnvOps m out_channel state file_descr sockaddr name msg input  = EnvOps {
    -- yieldLogEvents assumes the only newlines are betwee
    -- log events
    -- yields nothing when reaches end of file
    open :: String -> m file_descr
    ,yieldLogEvents ::  file_descr -> m (Maybe (LogStep name msg input))
    ,loadSnapShot :: String -> m state
  }

update_state_from_log_entry ::
  forall  state f  output name  msg input request_id
        . Functor f
         => Arrangement f name state input output msg request_id
         -> name
         -> state
         -> LogStep name msg input -> f state
update_state_from_log_entry arr nm s op  =
    ((\(_,st,_)-> st) . unRes) <$> case op of
        LogInput inp  ->  handleIO arr nm inp s
        LogNet src m -> handleNet arr nm src m s
        LogTimeout -> handleTimeout arr nm s

get_initial_state :: forall
            f   -- (f :: * -> *)
            out_channel
            file_descr
            sockaddr
            state
            name
            msg
            input
            output
            message
            request_id .
     Alternative f =>
     EnvOps f out_channel state file_descr sockaddr name msg input
     -> Arrangement f name state input output message request_id
     -> String
     -> name
     -> f state
get_initial_state eop arr snpfile nm =
    loadSnapShot eop snpfile <|>  pure (init arr nm)




restore_from_log :: forall
           m -- (m :: * -> *)
           out_channel
           state
           file_descr
           sockaddr
           name
           msg
           input
           output
           request_id.
    Monad m =>
    Arrangement m name state input output msg request_id
    -> EnvOps m out_channel state file_descr sockaddr name msg input
    -> file_descr
    -> name
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

restore :: forall  m -- (m :: * -> *)
      state
       -- (m1 :: * -> *)
      output
      request_id
      out_channel
      file_descr
      sockaddr
      name
      msg
      input .
     (Monad m, Alternative m)
   => Arrangement m name state input output msg request_id
     -- -> Arrangement m name state input output msg request_id
     -> EnvOps m out_channel state file_descr sockaddr name msg input
     -> String
     -> String
     -> name
     -> m state
restore arr  eop snpfile logfl nm =
   do
    -- this doesn't deal with catching up with
    -- nonlocal update ... i think....
     istate <- get_initial_state eop arr snpfile nm
     logfd <- open eop logfl
     restore_from_log arr eop logfd nm istate


denote :: (Monad m,Ord name)
   => Env m  state out_channel file_descr request_id sockaddr name
   -> name -> m sockaddr
denote env nm =
  do  nds <- nodes env
      maybe
        (fail "bad lookup with denote")
        return
        $  Map.lookup  nm nds

