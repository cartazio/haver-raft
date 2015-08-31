{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}


module Network.Consensus.Verified.Fixture where

import Network.Consensus.Verified.Raft
import Data.Reflection
import qualified Data.Set as S
import qualified Data.Map.Strict as M

n1,n2,n3 :: Name
n1 = Name "N1"
n2 = Name "N2"
n3 = Name "N3"

allNames :: S.Set Name
allNames = S.fromList [n1,n2,n3]

newtype SMsg = SMsg String deriving (Eq,Show)
data SState = SState [SMsg] Int deriving (Eq,Show)
type TestStateMachine m = StateMachine m SMsg SState (SMsg, SState)

theStateMachine :: (Monad m) => TestStateMachine m
theStateMachine = StateMachine $ \(SState msgs c) msg -> return (SMsg "output", SState (msg:msgs) (succ c))

aTerm :: Term
aTerm = Term 1

raftData :: RaftData SState SMsg SMsg
raftData = RaftData aTerm Nothing Nothing [] (LogIndex 0) (LogIndex 0) (SState [] 0) M.empty M.empty False S.empty Follower M.empty []

runRaftInputHandler :: (Monad m) => m (Res
                                       (RaftOutput SMsg)
                                       (RaftData SState SMsg SMsg)
                                       (Msg SMsg))
runRaftInputHandler =
    reify allNames $ \pk ->
        reify theStateMachine $ \ps ->
            raftInputHandler ps pk n1 Timeout raftData
