{-#  LANGUAGE ScopedTypeVariables #-}

module Network.Message.Framing where


import Data.Typeable
import qualified Data.ByteString.Char8 as BSC
import Data.ByteString.Char8 (ByteString)
--import Data.Bytes.Serial as DBS
import Data.Bytes.Put as DBP
import Data.Bytes.Get as DBG
--import Data.Word
import Data.ByteString.Builder as DBB
import Control.Applicative ((<|>),Alternative)

newtype Message = Message { payload :: BSC.ByteString } deriving (Eq, Show,Typeable)

-- | LeftOvers!
newtype Residue =  Residue { prefix :: Builder} deriving (Typeable)



putMsg :: MonadPut m => Message -> m ()
putMsg msg = do putWord64be (fromIntegral $ BSC.length $ payload msg)
                putByteString $ payload msg


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
                              case (fromIntegral bytesLeft :: Int) of
                                  0 -> return $ Right $ reverse revList
                                  n | n >  8 ->
                                       do next <-  fmap Right headeredBS  <|> fmap Left ( ensure n)
                                          case next of
                                            Right newMsg -> go ( Message newMsg : revList)
                                            Left resid -> return $ Left (reverse revList, Residue $ DBB.byteString resid)
                                      -- n <= 8 case, but in a way that
                                      -- placates the coverage checker
                                    | otherwise  ->
                                        do resid<- ensure n
                                           return $ Left (reverse revList, Residue $ DBB.byteString resid)


              headeredBS :: m ByteString
              headeredBS  = do header <- getWord64be   ; ensure (fromIntegral header)

