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



data Arrangement m name state input output message request_id =
  Arrangement {
        init :: name -> state
        ,reboot :: state -> state
        ,handleIO :: name -> input -> state ->  m (Res output state name message)
        ,handleNet :: name -> name -> message -> state -> m (Res output state name message)
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
    ,setTimeout = Raft.handleTimeout pk
    ,deserialize = undefined
    ,serialize = undefined
    ,debug = False
    ,debugRecv = undefined
    ,debugSend = undefined
    ,debugTimeout = undefined
  }




data Env m  state out_channel file_descr request_id sockaddr name = Env {
    restored_state :: state
    ,clog :: out_channel
    ,usock :: file_descr
    ,isock :: file_descr
    ,csocksRead :: m [file_descr]
    ,csocksUpdate :: [file_descr] -> m ()
    ,outstandingRead :: m (Map request_id file_descr)
    ,outstandingUpdate ::  Map request_id file_descr -> m ()
    ,savesRead :: m Int
    ,savesWrite :: Int -> m ()
    ,nodes :: [(name,sockaddr)]
  }


data LogStep name msg input = LogInput input | LogNet name msg  | LogTimeout
  deriving (Eq,Ord,Show)

