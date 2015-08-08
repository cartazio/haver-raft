{-# LANGUAGE DeriveDataTypeable , DeriveGeneric #-}
module VerdiRaft.RaftData where

import Numeric.Natural
import Data.Data (Data,Typeable)
import GHC.Generics (Generic)

data RaftData term name entry logIndex serverType stateMachineData output =
    RaftData {
    -- persistent
      currentTerm :: term
      ,votedFor :: Maybe name
      ,leaderId :: Maybe name
      ,log :: [entry]
      -- volatile
      ,commitIdndex :: logIndex
      ,lastApplied :: logIndex
      ,stateMachine :: stateMachineData
      -- leader state
      ,nextIndex :: [(name,logIndex)]
      ,matchIndex :: [(name,logIndex)]
      ,shouldSend :: Bool
      -- candidate state
      ,votesReceived :: [name]
      -- whoami
      ,rdType :: serverType
      -- client request state
      ,clientCache :: [(Natural,(Natural,output))]
      -- ghost variables ---- but do we care?
      ,electoralVictories :: [(term,[name],[entry])]

  } deriving (Read,Show,Typeable,Data,Generic)
