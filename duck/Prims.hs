{-# LANGUAGE PatternGuards #-}
-- | Duck primitive operations

module Prims 
  ( prim
  , prelude
  , primIO
  ) where

import Var
import Type
import Value
import SrcLoc
import Pretty
import Ir
import qualified Lir
import ExecMonad
import Text.PrettyPrint

prim :: SrcLoc -> Binop -> Value -> Value -> Exec Value
prim _ IntAddOp (ValInt i) (ValInt j) = return $ ValInt (i+j)
prim _ IntSubOp (ValInt i) (ValInt j) = return $ ValInt (i-j)
prim _ IntMulOp (ValInt i) (ValInt j) = return $ ValInt (i*j)
prim _ IntDivOp (ValInt i) (ValInt j) = return $ ValInt (div i j)
prim _ IntEqOp (ValInt i) (ValInt j) = return $ ValCons (V (if i == j then "True" else "False")) []
prim _ IntLessOp (ValInt i) (ValInt j) = return $ ValCons (V (if i < j then "True" else "False")) []
prim loc op v1 v2 = execError loc ("invalid arguments "++show (pretty v1)++", "++show (pretty v2)++" to "++show op)

primIO :: PrimIO -> [Value] -> Exec Value
primIO ExitFailure [] = execError noLoc "exit failure"
primIO p args = execError noLoc ("invalid arguments "++show (hsep (map pretty args))++" to "++show p)

prelude :: Lir.Prog
prelude = Lir.prog $ decTuples ++ binops ++ io where
  [a,b] = take 2 standardVars
  ty = TyFun TyInt (TyFun TyInt (TyVar a))
  binops = map binop [IntAddOp, IntSubOp, IntMulOp, IntDivOp, IntEqOp, IntLessOp]
  binop op = Ir.Over (V (binopString op)) ty (Lambda a (Lambda b (Binop op (Var a) (Var b))))

  decTuples = map decTuple [2..5]
  decTuple i = Data c vars [(c, map TyVar vars)] where
    c = tuple vars
    vars = take i standardVars

io :: [Decl]
io = [map',join,exitFailure,testAll,returnIO] where
  [f,a,b,c,x] = map V ["f","a","b","c","x"]
  [ta,tb] = map TyVar [a,b]
  map' = Over (V "map") (TyFun (TyFun ta tb) (TyFun (TyIO ta) (TyIO tb)))
    (Lambda f (Lambda c
      (Bind x (Var c)
      (Return (Apply (Var f) (Var x))))))
  join = Over (V "join") (TyFun (TyIO (TyIO ta)) (TyIO ta))
    (Lambda c
      (Bind x (Var c)
      (Var x)))
  returnIO = LetD (V "returnIO") (Lambda x (Return (Var x)))
  exitFailure = LetD (V "exitFailure") (PrimIO ExitFailure [])
  testAll = LetD (V "testAll") (PrimIO TestAll [])
