{-# LANGUAGE PatternGuards, TypeSynonymInstances #-}
-- | Duck interpreter

-- For now, this is dynamically typed

module Interp 
  ( prog
  , main
  ) where

import Prelude hiding (lookup)
import Data.List hiding (lookup)
import Data.Maybe
import qualified Data.Map as Map
import Control.Monad hiding (guard)
import Control.Monad.Trans

import Util
import Var
import Type
import Prims
import Value
import SrcLoc
import Pretty
import Lir hiding (prog)
import ExecMonad
import qualified Infer
import qualified Base

-- Environments

-- Some aliases for documentation purposes
type Globals = Env
type Locals = Env
type LocalTypes = TypeEnv

lookup :: Globals -> Locals -> SrcLoc -> Var -> Exec Value
lookup global env loc v
  | Just r <- Map.lookup v env = return r -- check for local definitions first
  | Just r <- Map.lookup v global = return r -- fall back to global definitions
  | otherwise = getProg >>= lp where
  lp prog
    | Just _ <- Map.lookup v (progOverloads prog) = return (ValClosure v [] []) -- if we find overloads, make a new closure
    | Just _ <- Map.lookup v (progFunctions prog) = return (ValClosure v [] []) -- this should never be used
    | Just _ <- Map.lookup v (progDatatypes prog) = return ValType
    | otherwise = execError loc ("unbound variable " ++ qshow v)

-- |Process a list of definitions into the global environment.
prog :: Exec Globals
prog = getProg >>= foldM definition Map.empty . progDefinitions

definition :: Globals -> Definition -> Exec Globals
definition env d@(Def vl e) = withFrame (V $ intercalate "," $ map (unV . unLoc) vl) [] [] (loc d) $ do
  d <- expr env Map.empty Map.empty noLoc e
  dl <- case (vl,d) of
          ([_],_) -> return [d]
          (_, ValCons c dl) | isTuple c, length vl == length dl -> return dl
          _ -> execError noLoc ("expected "++show (length vl)++"-tuple, got "++qshow d)
  return $ foldl (\g (v,d) -> Map.insert v d g) env (zip (map unLoc vl) dl)

-- |A placeholder for when implicit casts stop being nops on the data.
cast :: Type -> Exec Value -> Exec Value
cast _ x = x

--runInfer :: SrcLoc -> Infer Type -> Exec Type
runInfer l f = do
  t <- liftInfer f
  when (t == TyVoid) $ execError l "<<void>>"
  return t

inferExpr :: LocalTypes -> SrcLoc -> Exp -> Exec Type
inferExpr env loc = runInfer loc . Infer.expr env loc

expr :: Globals -> LocalTypes -> Locals -> SrcLoc -> Exp -> Exec Value
expr global tenv env loc = exp where
  exp (Int i) = return (ValInt i)
  exp (Chr i) = return (ValChr i)
  exp (Var v) = lookup global env loc v
  exp (Apply e1 e2) = do
    t1 <- inferExpr tenv loc e1
    v1 <- exp e1
    applyExpr global tenv env loc t1 v1 e2
  exp (Let v e body) = do
    t <- inferExpr tenv loc e
    d <- exp e
    expr global (Map.insert v t tenv) (Map.insert v d env) loc body
  exp (Case _ [] Nothing) = execError loc ("pattern match failed: no cases")
  exp (Case _ [] (Just body)) = exp body
  exp ce@(Case v pl def) = do
    ct <- inferExpr tenv loc ce
    t <- liftInfer $ Infer.lookup tenv loc v
    conses <- liftInfer $ Infer.lookupDatatype loc t
    d <- lookup global env loc v
    case d of
      ValCons c dl ->
        case find (\ (c',_,_) -> c == c') pl of
          Just (_,vl,e') -> do
            let Just tl = Infer.lookupCons conses c
            cast ct $ expr global (insertList tenv vl tl) (insertList env vl dl) loc e'
          Nothing -> case def of
            Nothing -> execError loc ("pattern match failed: exp = " ++ qshow d ++ ", cases = " ++ show pl) -- XXX data printed
            Just e' -> cast ct $ expr global tenv env loc e' 
      ValType -> do
        let (c,vl,e') = head pl
            Just tl = Infer.lookupCons conses c
        cast ct $ expr global (insertList tenv vl tl) (foldl (\s v -> Map.insert v ValType s) env vl) loc e'
      _ -> execError loc ("expected block, got "++qshow v)
  exp (Cons c el) = ValCons c =.< mapM exp el
  exp (Prim op el) = Base.prim loc op =<< mapM exp el
  exp (Bind v e1 e2) = do
    t <- inferExpr tenv loc e1
    d <- exp e1
    return $ ValBindIO v t d tenv env e2
  exp (Return e) = ValLiftIO =.< exp e
  exp se@(Spec e _) = do
    t <- inferExpr tenv loc se
    cast t $ exp e
  exp (ExpLoc l e) = expr global tenv env l e

-- |Evaluate an argument acording to the given transform
transExpr :: Globals -> LocalTypes -> Locals -> SrcLoc -> Exp -> Maybe Trans -> Exec Value
transExpr global tenv env loc e Nothing = expr global tenv env loc e
transExpr _ tenv env _ e (Just Delayed) = return $ ValDelay tenv env e

applyExpr :: Globals -> LocalTypes -> Locals -> SrcLoc -> Type -> Value -> Exp -> Exec Value
applyExpr global tenv env loc ft f e =
  apply global loc ft f (transExpr global tenv env loc e)
    =<< inferExpr tenv loc e

-- Because of the delay mechanism, we pass in two things related to the argument
-- "a".  The first argument provides the argument itself, whose evaluation must
-- be delayed until we know the correct transform to apply.  The second type
-- "at" is the type of the value which was passed in, and is the type used for
-- type inference/overload resolution.
apply :: Globals -> SrcLoc -> Type -> Value -> (Maybe Trans -> Exec Value) -> Type -> Exec Value
apply global loc ft (ValClosure f types args) ae at = do
  -- infer return type
  rt <- runInfer loc $ Infer.apply loc ft at
  -- lookup appropriate overload (parallels Infer.apply/resolve)
  let tl = types ++ [at]
  o <- maybe 
    (execError loc ("unresolved overload: " ++ pshow f ++ " " ++ pshowlist tl))
    return =<< liftInfer (Infer.lookupOver f tl)
  -- determine type transform for this argument, and evaluate
  let tt = map fst $ overArgs o
  -- we throw away the type because we can reconstruct it later with argType
  a <- ae (tt !! length args)
  let dl = args ++ [a]
  case o of
    Over _ _ _ _ Nothing -> 
      -- partially applied
      return $ ValClosure f tl dl
    Over oloc tl' _ vl (Just e) -> do
      -- full function call (parallels Infer.cache)
      let tl = map snd tl'
      cast rt $ withFrame f tl dl loc $ expr global (Map.fromList $ zip vl tl) (Map.fromList $ zip vl dl) oloc e
apply global loc ft (ValDelay tenv env e) _ at = do
  rt <- runInfer loc $ Infer.apply loc ft at
  cast rt $ expr global tenv env loc e
apply _ _ _ ValType _ _ = return ValType
apply _ loc t1 v1 e2 t2 = e2 Nothing >>= \v2 -> execError loc ("can't apply '"++pshow v1++" :: "++pshow t1++"' to '"++pshow v2++" :: "++pshow t2++"'")

-- |IO and main
main :: Prog -> Globals -> IO ()
main prog global = runExec prog $ do
  main <- lookup global Map.empty noLoc (V "main")
  _ <- runIO global main
  return ()

runIO :: Globals -> Value -> Exec Value
runIO _ (ValLiftIO d) = return d
runIO global (ValPrimIO TestAll []) = testAll global
runIO _ (ValPrimIO p args) = Base.runPrimIO p args
runIO global (ValBindIO v tm m tenv env e) = do
  d <- runIO global m
  t <- liftInfer $ Infer.runIO tm
  d' <- expr global (Map.insert v t tenv) (Map.insert v d env) noLoc e
  runIO global d'
runIO _ d = execError noLoc ("expected IO computation, got "++qshow d)

testAll :: Globals -> Exec Value
testAll global = do
  liftIO $ puts "running unit tests..."
  mapM_ test (Map.toList global)
  liftIO $ puts "success!"
  nop
  where
  test (V v,d)
    | isPrefixOf "test_" v = do
        liftIO $ puts ("  "++v)
        runIO global d
        success
    | otherwise = success
  nop = return $ ValCons (V "()") []

