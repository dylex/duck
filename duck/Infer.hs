{-# LANGUAGE PatternGuards, ScopedTypeVariables #-}
-- | Duck type inference

module Infer
  ( prog
  , expr
  , apply
  , typeInfo
  , resolve
  , lookupOver
  , lookupDatatype
  , lookupCons
  , lookupConstructor
  , lookupVariances
  , runIO
  , main
  ) where

import Var
import Type
import Prims
import Util
import Pretty
import Lir hiding (prog, union)
import qualified Data.Map as Map
import Data.List hiding (lookup, union)
import qualified Data.List as List
import Control.Monad.Error hiding (guard, join)
import InferMonad
import qualified Ptrie
import Prelude hiding (lookup)
import qualified Base
import Data.Maybe
import SrcLoc

---- Algorithm discussion:

-- The state of the type inference algorithm consists of
--
-- 1. A set of function type primitives (functors) representing maps from types to types.
-- 2. A map from variables to (possibly primitive) types.
-- 3. A set of in-progress type applications to compute fixed points in the case of recursion.

-- Some aliases for documentation purposes

type Locals = TypeEnv

-- Utility functions

insertOver :: Var -> [(Maybe Trans, Type)] -> Overload Type -> Infer ()
insertOver f a o = do
  --debugInfer ("recorded "++pshow f++" "++pshowlist a++" = "++pshow (overRet o))
  updateInfer $ Ptrie.mapInsert f a o

lookupOver :: Var -> [Type] -> Infer (Maybe (Either (Maybe Trans) (Overload Type)))
lookupOver f tl = getInfer >.=
  (fmap Ptrie.unPtrie . Ptrie.lookup tl <=< Map.lookup f)

lookupOverTrans :: Var -> [Type] -> Infer [Maybe Trans]
lookupOverTrans f tl = getInfer >.=
  maybe [] (Ptrie.assocs tl) . Map.lookup f

transOvers :: [Overload t] -> Int -> Maybe [Maybe Trans]
transOvers [] _ = Nothing
transOvers os n = if all (tt ==) tts then Just tt else Nothing 
  where tt:tts = map (map fst . (take n) . overArgs) os

lookup :: Prog -> Locals -> SrcLoc -> Var -> Infer Type
lookup prog env loc v
  | Just r <- Map.lookup v env = return r -- check for local definitions first
  | Just r <- Map.lookup v (progGlobalTypes prog) = return r -- fall back to global definitions
  | Just _ <- Map.lookup v (progFunctions prog) = return $ tyClosure v [] -- if we find overloads, make a new closure
  | Just _ <- Map.lookup v (progVariances prog) = return $ tyType (TyCons v []) -- found a type constructor, return Type v
  | otherwise = typeError loc ("unbound variable " ++ qshow v)

lookupDatatype :: Prog -> SrcLoc -> CVar -> [Type] -> Infer [(Loc CVar, [Type])]
lookupDatatype _ loc (V "Type") [t] = case t of
  TyCons c tl -> return [(Loc noLoc c, map tyType tl)]
  TyVoid -> return [(Loc noLoc (V "Void"), [])]
  TyFun _ -> typeError loc ("can't pattern match on "++qshow (tyType t)++"; matching on function types isn't implemented yet")
lookupDatatype prog loc tv types
  | Just (Data _ vl cons) <- Map.lookup tv (progDatatypes prog) = return $ map (second $ map $ substVoid $ Map.fromList $ zip vl types) cons
  | otherwise = typeError loc ("unbound datatype constructor " ++ qshow tv)

lookupOverloads :: Prog -> SrcLoc -> Var -> Infer [Overload TypeSet]
lookupOverloads prog loc f
  | Just o <- Map.lookup f (progFunctions prog) = return o
  | otherwise = typeError loc ("unbound function " ++ qshow f)

lookupConstructor :: Prog -> SrcLoc -> Var -> Infer (CVar, [Var], [TypeSet])
lookupConstructor prog loc c
  | Just tc <- Map.lookup c (progConses prog)
  , Just td <- Map.lookup tc (progDatatypes prog)
  , Just tl <- lookupCons (dataConses td) c 
  = return (tc,dataTyVars td,tl)
  | otherwise = typeError loc ("unbound constructor " ++ qshow c)

lookupCons :: [(Loc CVar, [t])] -> CVar -> Maybe [t]
lookupCons cases c = fmap snd (List.find ((c ==) . unLoc . fst) cases)

-- Process a list of definitions into the global environment.
-- The global environment is threaded through function calls, so that
-- functions are allowed to refer to variables defined later on as long
-- as the variables are defined before the function is executed.
prog :: Prog -> Infer Prog
prog prog = do
  prog <- foldM definition prog (progDefinitions prog)
  info <- getInfer
  return $ prog{ progOverloads = info }

definition :: Prog -> Definition -> Infer Prog
definition prog d@(Def vl e) = withFrame (V $ intercalate "," $ map (unV . unLoc) vl) [] (loc d) $ do
  t <- expr prog Map.empty noLoc e
  tl <- case (vl,t) of
          ([_],_) -> return [t]
          (_, TyCons c tl) | istuple c, length vl == length tl -> return tl
          _ -> typeError noLoc ("expected "++show (length vl)++"-tuple, got "++pshow t)
  return $ prog { progGlobalTypes = foldl (\g (v,t) -> Map.insert (unLoc v) t g) (progGlobalTypes prog) (zip vl tl) }

expr :: Prog -> Locals -> SrcLoc -> Exp -> Infer Type
expr prog env loc = exp where
  exp (Int _) = return tyInt
  exp (Chr _) = return tyChr
  exp (Var v) = lookup prog env loc v
  exp (Apply e1 e2) = do
    t1 <- exp e1
    t2 <- exp e2
    apply prog t1 t2 loc
  exp (Let v e body) = do
    t <- exp e
    expr prog (Map.insert v t env) loc body
  exp (Case _ [] Nothing) = return TyVoid
  exp (Case _ [] (Just body)) = exp body
  exp (Case v pl def) = do
    t <- lookup prog env loc v
    case t of
      TyVoid -> return TyVoid
      TyCons tv types -> do
        conses <- lookupDatatype prog loc tv types
        let caseType (c,vl,e')
              | Just tl <- lookupCons conses c, a <- length tl =
                  if length vl == a then
                    expr prog (foldl (\e (v,t) -> Map.insert v t e) env (zip vl tl)) loc e'
                  else
                    typeError loc ("arity mismatch in pattern: "++qshow c++" expected "++show a++" argument"++(if a == 1 then "" else "s")
                      ++" but got ["++intercalate ", " (map pshow vl)++"]")
              | otherwise = typeError loc ("datatype "++qshow tv++" has no constructor "++qshow c)
            defaultType Nothing = return []
            defaultType (Just e') = expr prog env loc e' >.= (:[])
        caseResults <- mapM caseType pl
        defaultResults <- defaultType def
        joinList prog loc (caseResults ++ defaultResults)
      _ -> typeError loc ("expected datatype, got "++qshow t)
  exp (Cons c el) = do
    args <- mapM exp el
    (tv,vl,tl) <- lookupConstructor prog loc c
    result <- runMaybeT $ subsetList (typeInfo prog) args tl
    case result of
      Just (tenv,[]) -> return $ TyCons tv targs where
        targs = map (\v -> Map.findWithDefault TyVoid v tenv) vl
      _ -> typeError loc (qshow c++" expected arguments "++pshowlist tl++", got "++pshowlist args)
  exp (Prim op el) =
    Base.primType loc op =<< mapM exp el
  exp (Bind v e1 e2) = do
    t1 <- runIO =<< exp e1
    t2 <- expr prog (Map.insert v t1 env) loc e2
    checkIO t2
  exp (Return e) =
    exp e >.= tyIO
  exp (PrimIO p el) = mapM exp el >>= Base.primIOType loc p >.= tyIO
  exp (Spec e ts) = do
    t <- exp e
    result <- runMaybeT $ subset (typeInfo prog) t ts
    case result of
      Just (tenv,[]) -> return $ substVoid tenv ts
      Nothing -> typeError loc (qshow e++" has type "++qshow t++", which is incompatible with type specification "++qshow ts)
      Just (_,leftovers) -> typeError loc ("type specification "++qshow ts++" is invalid; can't overload on contravariant "++showContravariantVars leftovers)
  exp (ExpLoc l e) = expr prog env l e

join :: Prog -> SrcLoc -> Type -> Type -> Infer Type
join prog loc t1 t2 = do
  result <- runMaybeT $ union (typeInfo prog) t1 t2
  case result of
    Just t -> return t
    _ -> typeError loc ("failed to unify types "++qshow t1++" and "++qshow t2)

-- In future, we might want this to produce more informative error messages
joinList :: Prog -> SrcLoc -> [Type] -> Infer Type
joinList prog loc = foldM1 (join prog loc)

apply :: Prog -> Type -> Type -> SrcLoc -> Infer Type
apply _ TyVoid _ _ = return TyVoid
apply _ _ TyVoid _ = return TyVoid
apply prog (TyFun (TypeFun al cl)) t2 loc = do
  al <- mapM arrow al
  cl <- mapM closure cl
  joinList prog loc (al++cl)
  where
  arrow :: (Type,Type) -> Infer Type
  arrow (a,r) = do
    result <- runMaybeT $ subset'' (typeInfo prog) t2 a
    case result of
      Just () -> return r
      Nothing -> typeError loc ("cannot apply "++qshow (tyArrow a r)++" to "++qshow t2)
  closure :: (Var,[Type]) -> Infer Type
  closure (f,args) = do
    r <- lookupOver f args'
    case r of
      Nothing -> apply' prog f args' loc -- no match, type not yet inferred
      Just (Right t) -> return (overRet t) -- fully applied
      Just (Left _) -> return $ tyClosure f args' -- partially applied
    where args' = args ++ [t2]
apply prog t1 t2 loc | Just (TyCons c tl) <- isTyType t1, Just t <- isTyType t2 =
  if length tl < length (lookupVariances prog c) then
    return (tyType (TyCons c (tl++[t])))
  else
    typeError loc ("can't apply "++qshow t1++" to "++qshow t2++", "++qshow c++" is already fully applied")
apply _ t1 t2 loc = typeError loc ("can't apply "++qshow t1++" to "++qshow t2)

typeInfo :: Prog -> TypeInfo (MaybeT Infer)
typeInfo prog = TypeInfo
  { typeApply = applyTry prog
  , typeVariances = lookupVariances prog
  }

applyTry :: Prog -> Type -> Type -> MaybeT Infer Type
applyTry prog f t = catchError (lift $ apply prog f t noLoc) (\_ -> nothing)

lookupVariances :: Prog -> Var -> [Variance]
lookupVariances prog c | Just vars <- Map.lookup c (progVariances prog) = vars
lookupVariances _ _ = [] -- return [] instead of bailing so that skolemization works cleanly

-- Resolve an overload.  A result of Nothing means all overloads are still partially applied.
resolve :: Prog -> Var -> [Type] -> SrcLoc -> Infer (Either [Maybe Trans] (Overload TypeSet))
resolve prog f args loc = do
  rawOverloads <- lookupOverloads prog loc f -- look up possibilities
  let prune o = runMaybeT $ subsetList (typeInfo prog) args (overTypes o) >. o
  overloads <- catMaybes =.< mapM prune rawOverloads -- prune those that don't match
  let isSpecOf :: Overload TypeSet -> Overload TypeSet -> Bool
      isSpecOf a b = specializationList (overTypes a) (overTypes b)
      isMinimal o = all (\o' -> isSpecOf o o' || not (isSpecOf o' o)) overloads
      filtered = filter isMinimal overloads -- prune away overloads which are more general than some other overload
      options overs = concatMap (\ o -> "\n  "++pshow (foldr tsArrow (overRet o) (overTypes o))) overs
      call = qshow $ pretty f <+> prettylist args
  case filtered of
    [] -> typeError loc (call++" doesn't match any overload, possibilities are"++options rawOverloads)
    os -> case partition ((length args ==) . length . overVars) os of
      ([],os) -> maybe -- all overloads are still partially applied
        (typeError loc (call ++ " has conflicting type transforms with other overloads"))
        (return . Left)
        $ transOvers os (succ $ length args) -- one day the succ might be able to go away
      ([o],[]) -> return (Right o) -- exactly one fully applied option
      (fully,[]) -> typeError loc (call++" is ambiguous, possibilities are"++options fully)
      (fully,partially) -> typeError loc (call++" is ambiguous, could either be fully applied as"++options fully++"\nor partially applied as"++options partially)

-- Overloaded function application
apply' :: Prog -> Var -> [Type] -> SrcLoc -> Infer Type
apply' prog f args loc = do
  overload <- resolve prog f args loc
  let tt = either id (map fst . overArgs) overload
  ctt <- lookupOverTrans f args
  unless (and $ zipWith (==) tt ctt) $
    typeError loc (qshow (pretty f <+> prettylist args) ++ " has conflicting type transforms with other overloads")
  case overload of
    Left tt -> do
      let t = tyClosure f args
      insertOver f (zip tt args) (Over noLoc [] t [] Nothing)
      return t
    Right o -> cache prog f args o loc

-- Type infer a function call and cache the results
-- The overload is assumed to match, since this is handled by apply.
--
-- TODO: cache currently infers every nonvoid function call at least twice, regardless of recursion.  Fix this.
-- TODO: we should tweak this so that only intermediate (non-fixpoint) types are recorded into a separate map, so that
-- they can be easily rolled back in SFINAE cases _without_ rolling back complete computations that occurred in the process.
cache :: Prog -> Var -> [Type] -> Overload TypeSet -> SrcLoc -> Infer Type
cache prog f args (Over oloc atypes r vl e) loc = do
  let (tt,types) = unzip atypes
  Just (tenv, leftovers) <- runMaybeT $ subsetList (typeInfo prog) args types
  let call = qshow (pretty f <+> prettylist args)
  unless (null leftovers) $ 
    typeError loc (call++" uses invalid overload "++qshow (foldr tsArrow r types)++"; can't overload on contravariant "++showContravariantVars leftovers)
  let al = zip tt args
      tl = map (argType . fmap (substVoid tenv)) atypes
      rs = substVoid tenv r
      fix prev e = do
        insertOver f al (Over oloc (zip tt tl) prev vl (Just e))
        r' <- withFrame f args loc (expr prog (Map.fromList (zip vl tl)) oloc e)
        result <- runMaybeT $ union (typeInfo prog) r' rs
        case result of
          Nothing -> typeError loc ("in call "++call++", failed to unify result "++qshow r'++" with return signature "++qshow rs)
          Just r 
            | r == prev -> return prev
            | otherwise -> fix r e
  maybe (return TyVoid) (fix TyVoid) e -- recursive function calls are initially assumed to be void

-- Verify that main exists and has type IO ().
main :: Prog -> Infer ()
main prog = do
  main <- lookup prog Map.empty noLoc (V "main")
  result <- runMaybeT $ subset'' (typeInfo prog) main (tyIO tyUnit)
  case result of
    Just () -> success
    Nothing -> typeError noLoc ("main has type "++qshow main++", but should have type IO ()")

-- This is the analog for Interp.runIO for types.  It exists by analogy even though it is very simple.
runIO :: Type -> Infer Type
runIO io | Just t <- isTyIO io = return t
runIO t = typeError noLoc ("expected IO type, got "++qshow t)

-- Verify that a type is in IO, and leave it unchanged if so
checkIO :: Type -> Infer Type
checkIO t = tyIO =.< runIO t
