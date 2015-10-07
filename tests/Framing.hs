module Main where

import Network.Message.Framing
import Test.Hspec
import qualified Data.ByteString.Lazy.Char8 as LBSC
import Data.ByteString.Lazy.Char8 (ByteString)
import Data.Monoid((<>))

main = hspec $ do
  it "handles split messages" $
    let x =  (Message$ LBSC.pack "hello dotty!")
        y =  (Message$ LBSC.pack "whats up doc")
      in
          [x,y] `shouldBe`  (either (error "fail")  id $ prependAndGetMessage emptyResidue (putMsg x <> putMsg y ))

