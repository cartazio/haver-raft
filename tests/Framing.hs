module Main where

import Network.Message.Framing
import Test.Hspec
import qualified Data.ByteString.Lazy.Char8 as LBSC
import Data.Monoid((<>))
import Data.ByteString.Builder as DBB
main :: IO ()
main = hspec $ do
  it "handles multiple messages" $
    let x =  (Message$ LBSC.pack "hello dotty!")
        y =  (Message$ LBSC.pack "whats up doc")
      in
          [x,y] `shouldBe`  (either (error "fail")  id $ prependAndGetMessage emptyResidue (putMsg x <> putMsg y ))
  it "handles split messages" $
      let  z = (Message $ LBSC.pack "hello dotty!")
           x = putMsg z
           x' = Residue $ DBB.lazyByteString $  LBSC.take 3 x
           y' =  LBSC.drop 3 x
        in [z] `shouldBe` (either (error "split fail") id $ prependAndGetMessage x' y' )
  it "handles prefixes" $
      let  z = (Message $ LBSC.pack "hello dotty!")
           x = putMsg z
           x' =  LBSC.take 3 x
           --y' =  LBSC.drop 3 x
        in x' `shouldBe` ( DBB.toLazyByteString $ prefix $ either snd (error "prefix fail ")
                          $ prependAndGetMessage emptyResidue x')


