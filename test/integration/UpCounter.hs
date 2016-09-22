data Bit = Zero | One

data W8 = W8 Bit Bit Bit Bit Bit Bit Bit Bit

plusOne :: W8 -> W8
{-# INLINE plusOne #-}
plusOne = nativeVhdl "prim_plusOne" undefined

rotl :: W8 -> W8
{-# INLINE rotl #-}
rotl = nativeVhdl "prim_rotl" undefined

tick :: ReT Bit W8 (StT W8 I) Bit
{-# INLINE tick #-}
tick = lift get >>= \ x -> signal x

main :: ReT Bit W8 (StT W8 I) ()
main = do
      b <- tick
      case b of
            One -> lift get >>= \n -> lift (put (plusOne n))
            Zero -> lift get >>= \n -> lift (put (rotl n))
      main

start :: ReT Bit W8 I ((),W8)
start = extrude main (W8 Zero Zero Zero Zero Zero Zero Zero Zero)
