{-#  LANGUAGE ScopedTypeVariables #-}

module Network.Message.Framing(getSimpleMsg
    ,prependResidue
    ,Message(..)
    ,Residue(..)
    ,prependAndGetMessage
    ,putMsg
    ,putMsgGen
    ,emptyResidue
    ) where

import Control.Monad (unless)

import Data.Int
import Data.Typeable
import qualified Data.ByteString.Lazy.Char8 as LBSC
import Data.ByteString.Lazy.Char8 (ByteString)
--import Data.Bytes.Serial as DBS
import Data.Bytes.Put as DBP
import Data.Bytes.Get as DBG
--import Data.Word
import Data.ByteString.Builder as DBB
import Control.Applicative ((<|>),Alternative)
import Data.Monoid ((<>))

newtype Message = Message { payload :: LBSC.ByteString } deriving (Eq, Show,Typeable)

-- | LeftOvers!
newtype Residue =  Residue { prefix :: Builder} deriving (Typeable)



putMsgGen :: MonadPut m => Message -> m ()
putMsgGen msg = do putWord64be (fromIntegral $ LBSC.length $ payload msg)
                   DBP.putLazyByteString $ payload msg

putMsg :: Message -> ByteString
putMsg msg = runPutL $ putMsgGen msg

prependAndGetMessage ::
         Residue
      -> ByteString
      -> Either ([Message],Residue)  [Message]
prependAndGetMessage res bs = runGetL getSimpleMsg $ prependResidue res bs


emptyResidue :: Residue
emptyResidue = Residue mempty

prependResidue :: Residue -> ByteString -> ByteString
prependResidue (Residue res) bs = DBB.toLazyByteString $ res <> DBB.lazyByteString bs

{- | getSimpleMsg is a message framing parser that is designed to be well behaved
when reading from a potentially unbounded byteStream!
no profiling has been done that this actually is a good idea :)
and it probably is a horribly idea for performance reasons!
-}
getSimpleMsg :: forall m . (MonadGet m, Alternative m) => m (Either ([Message],Residue)  [Message] )
getSimpleMsg = go []
        where
              go :: [Message]        ->  m (Either ([Message],Residue)  [Message] )
              go revList = do bytesLeft <- remaining
                              case fromIntegral bytesLeft  of
                                  0 -> return $ Right $ reverse revList
                                  n | n >  8 ->
                                       do next <-  fmap Right headeredBS  <|> fmap Left ( ensure n)
                                          case next of
                                            Right newMsg -> go ( Message newMsg : revList)
                                            Left resid -> return $ Left (reverse revList, Residue $ DBB.byteString resid)
                                      -- n <= 8 case, but in a way that
                                      -- placates the coverage checker
                                    | otherwise  ->
                                        do resid<- ensureLazyBS $ fromIntegral n
                                           return $ Left (reverse revList, Residue $ DBB.lazyByteString resid)


              headeredBS :: m ByteString
              headeredBS  = do header <- getWord64be   ; ensureLazyBS (fromIntegral header)

              ensureLazyBS :: Int64 -> m ByteString
              ensureLazyBS bct = do   rest <- remaining ;
                                      unless ( bct <= fromIntegral rest )
                                        $ fail "ensureLazyBS required more bytes"
                                      getLazyByteString bct

