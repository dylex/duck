{-# LANGUAGE PatternGuards, FlexibleInstances, TypeSynonymInstances #-}
-- | Duck Intermediate Representation
-- 
-- Conversion of "Ast" into intermediate functional representation.

module Ir 
  ( Decl(..)
  , Exp(..)
  , TypePat(..), TypeFun(..)
  , prog
  ) where

import Control.Monad
import qualified Data.Foldable as Fold
import Data.Function
import Data.Functor
import Data.List
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe
import Data.Monoid
import qualified Data.Set as Set

import Util
import Pretty
import SrcLoc
import Var
import Stage
import ParseOps
import IrType
import qualified Ast
import Prims hiding (typeInt, typeChar, typeArrow)

-- |Top-level declaration
data Decl
  = LetD !(Loc Var) Exp                 -- ^ Single symbol definition, either a variable or a function without a corresponding type specification (with 'Lambda'): @VAR = EXP@
  | LetM [Loc Var] Exp                  -- ^ Tuple assignment/definition, from a pattern definition with 0 or more than 1 variable: @(VARs) = EXP@
  | ExpD Exp                            -- ^ Top level expression: @EXP@
  | Over !(Loc Var) !TypePat Exp        -- ^ Overload paired type declaration and definition: @VAR :: TYPE = EXP@
  | Data !(Loc CVar) [Var] [(Loc CVar, [TypePat])] -- ^ Datatype declaration: @data CVAR VARs = { CVAR TYPEs ; ... }@
  deriving Show

type Static = Bool

-- |Expression
data Exp
  = ExpLoc SrcLoc !Exp                  -- ^ Meta source location information, present at every non-generated level
  | Int !Int
  | Char !Char
  | Var !Var
  | Lambda !Var Exp                     -- ^ Simple lambda expression: @VAR -> EXP@
  | Apply Exp Exp                       -- ^ Application: @EXP EXP@
  | Let !Static !Var Exp Exp            -- ^ Simple variable assignment: @let VAR = EXP in EXP@
  | Case !Static Var [(CVar, [Var], Exp)] (Maybe Exp) -- ^ @case VAR of { CVAR VARs -> EXP ; ... [ ; _ -> EXP ] }@
  | Prim !Prim [Exp]                    -- ^ Primitive function call: @PRIM EXPs@
  | Spec Exp !TypePat                   -- ^ Type specification: @EXP :: TYPE@
  deriving Show

infixr 1 `Lambda`

-- Ast to IR conversion

data Pattern = Pat 
  { patVars :: [Var]
  , patSpec :: [TypePat]
  , patCons :: Maybe (CVar, [Pattern])
  , patCheck :: Maybe (Var -> Exp) -- :: Bool
  }

data CaseTail
  = CaseGroup !Bool [Switch]
  | CaseBody Exp

data Case = CaseMatch
  { casePat :: [Pattern]
  , _caseLets :: Exp -> Exp
  , _caseNext :: CaseTail
  }

data Switch = Switch 
  { _switchVal :: [Exp]
  , switchCases :: [Case]
  }

irError :: Pretty s => SrcLoc -> s -> a
irError l = fatal . locMsg l

dupError :: Pretty v => v -> SrcLoc -> SrcLoc -> a
dupError v n o = irError n $ "duplicate definition of" <+> quoted v <> (", previously declared at" <&+> o)

progVars :: Ast.Prog -> InScopeSet
progVars = foldl' declVars Set.empty . map unLoc

declVars :: InScopeSet -> Ast.Decl -> InScopeSet
declVars s (Ast.SpecD (L _ v) _) = Set.insert v s 
declVars s (Ast.DefD (L _ v) _ _) = Set.insert v s 
declVars s (Ast.LetD p _) = patternVars s p
declVars s (Ast.ExpD _) = s
declVars s (Ast.Data _ _ _) = s
declVars s (Ast.Infix _ _) = s
declVars s (Ast.Import _) = s

patternVars :: InScopeSet -> Ast.Pattern -> InScopeSet
patternVars s Ast.PatAny = s
patternVars s (Ast.PatVar v) = Set.insert v s
patternVars s (Ast.PatInt _) = s
patternVars s (Ast.PatChar _) = s
patternVars s (Ast.PatString _) = s
patternVars s (Ast.PatCons _ pl) = foldl' patternVars s pl
patternVars s (Ast.PatOps o) = Fold.foldl' patternVars s o
patternVars s (Ast.PatList pl) = foldl' patternVars s pl
patternVars s (Ast.PatAs v p) = patternVars (Set.insert v s) p
patternVars s (Ast.PatSpec p _) = patternVars s p
patternVars s (Ast.PatLambda pl p) = foldl' patternVars (patternVars s p) pl
patternVars s (Ast.PatTrans _ p) = patternVars s p
patternVars s (Ast.PatLoc _ p) = patternVars s p

progPrecs :: PrecEnv -> Ast.Prog -> PrecEnv
progPrecs = foldl' set_precs where
  set_precs s (L l (Ast.Infix p vl)) = foldl' (\s v -> Map.insertWithKey check v p s) s vl where
    check v new old
      | new == old = new
      | otherwise = irError l $ "conflicting fixity declaration for" <+> quoted v <+> "(previously" <+> old <+> ")"
  set_precs s _ = s

instance HasVar Exp where
  unVar (Var v) = Just v
  unVar (ExpLoc _ e) = unVar e
  unVar _ = Nothing

letVarIf :: Static -> Var -> Exp -> Exp -> Exp
letVarIf tr var val exp
  | Just v <- unVar val
  , v == var = exp
  | otherwise = Let tr var val exp

anyPat :: Pattern
anyPat = Pat [] [] Nothing Nothing

instance HasVar Pattern where
  unVar (Pat{ patVars = v:_ }) = Just v
  unVar _ = Nothing

consPat :: CVar -> [Pattern] -> Pattern
consPat c pl = Pat [] [] (Just (c,pl)) Nothing

addPatVar :: Var -> Pattern -> Pattern
addPatVar v p = p { patVars = v : patVars p }

addPatSpec :: TypePat -> Pattern -> Pattern
addPatSpec t p = p { patSpec = t : patSpec p }

patLets :: Static -> Var -> Pattern -> Exp -> Exp
patLets tr var (Pat vl tl _ _) e = case (vl', tl) of
  ([],[]) -> e
  ([],_) -> Let tr ignored spec e
  (v:vl,_) -> letVarIf tr v spec $ foldr (\v -> Let tr v $ Var var) e vl
  where 
    spec = foldl' Spec (Var var) tl
    (_:vl') = nub (var:vl)

patName :: InScopeSet -> Pattern -> (InScopeSet, Var)
patName s (Pat{ patVars = v:_ }) = (s, v)
patName s (Pat{ patVars = [] }) = fresh s 

patNames :: InScopeSet -> Int -> [Pattern] -> (InScopeSet, [Var])
patNames s 0 _ = (s, [])
patNames s n [] = freshVars s n
patNames s n (p:pl) = second (v:) $ patNames s' (pred n) pl where (s',v) = patName s p 

patsNames :: InScopeSet -> Int -> [[Pattern]] -> (InScopeSet, [Var])
patsNames s n [p] = patNames s n p
patsNames s n _ = freshVars s n

destaticType :: TypePat -> Maybe TypePat
destaticType (TsTrans (V "static") t) = Just t
destaticType _ = Nothing

staticArgs :: TypePat -> [Static]
staticArgs (TsFun [FunArrow t r]) = (isJust $ destaticType t) : staticArgs r
staticArgs _ = []

destaticPattern :: Ast.Pattern -> Maybe Ast.Pattern
destaticPattern (Ast.PatTrans (V "static") p) = Just p
destaticPattern _ = Nothing

mapss :: (a -> (InScopeSet, b)) -> [a] -> (InScopeSet, [b])
--mapss f = first Set.unions . unzipWith f l
mapss f = mapAccumL (\s -> first (Set.union s) . f) Set.empty

prog :: PrecEnv -> ModuleName -> Ast.Prog -> (PrecEnv, (ModuleName, [Decl]))
prog pprec name p = (precs, (name, decls [] p)) where
  precs = progPrecs pprec p
  globals = progVars p

  -- Declaration conversion can turn multiple Ast.Decls into a single Ir.Decl, as with
  --   f :: <type>
  --   f x = ...
  decls :: [Static] -> [Loc Ast.Decl] -> [Decl]
  decls _ [] = []
  decls st decs@(L _ (Ast.DefD (L _ f) _ _):_) = LetD (L l f) body : decls [] rest where
    (L l body, rest) = funcases globals f isfcase st decs
    isfcase (L l (Ast.DefD (L _ f') a b)) | f == f' = Just (L l (a,b))
    isfcase _ = Nothing
  decls _ (L l (Ast.SpecD (L _ f) t) : rest) = case decls (staticArgs t) rest of
    LetD (L l' f') e : rest | f == f' -> Over (L (mappend l l') f) t e : rest
    _ -> irError l $ "type specification for" <+> quoted f <+> "must be followed by its definition"
  decls _ (L l (Ast.LetD ap ae) : rest) = d : decls [] rest where
    d = case Map.toList vm of
      [] -> LetD (L l ignored) $ body $ Var (V "()")
      [(v,l)] -> LetD (L l v) $ body $ Var v
      vl -> LetM (map (\(v,l) -> L l v) vl) $ body $ foldl' Apply (Var $ tupleCons vl) (map (Var . fst) vl)
    body r = match [isJust ap'] globals [Switch [e] [CaseMatch [p] id (CaseBody r)]] Nothing
    e = expr globals l ae
    ap' = destaticPattern ap
    (p,vm) = pattern' Map.empty l (fromMaybe ap ap')
  decls _ (L l (Ast.ExpD e) : rest) = ExpD (expr globals l e) : decls [] rest
  decls _ (L _ (Ast.Data t args cons) : rest) = dd : fd ++ decls [] rest where
    dd = Data t args $ map (second $ map Ast.fieldType) cons
    fd = fields t args cons
  decls _ (L _ (Ast.Infix _ _) : rest) = decls [] rest
  decls _ (L _ (Ast.Import _) : rest) = decls [] rest

  fields :: Loc CVar -> [Var] -> [Ast.DataCon] -> [Decl]
  fields (L l t) ta = ff <=< groupPairs . fm where
    (tas, fieldty) = fresh $ Set.fromList ta
    taa = ap (second . (. TsVar) . (,)) . freshen
    tam = Map.fromAscList $ snd $ ap (mapAccumL taa) Set.toAscList tas
    dataty  = TsCons t $ map TsVar ta
    dataty' = TsCons t $ map (tam Map.!) ta -- typeSubst tam dataty
    datavar:mutvar:argvars = standardVars
    ff (fn, tcc) =
      -- TODO: proper semantics/errors for field not found (fall cases)
      [ Over (L l fn) aty $ datavar `Lambda` casef fst Nothing
      , Over (L l fn) mty $ mutvar `Lambda` datavar `Lambda` casef snd Nothing
      ] where
      casef f = Case False datavar (map (third f) cc)
      (tys, cc) = unzip tcc -- TODO: nub tys?
      aty = dataty `typeArrow` TsVar fieldty
      mty = TsFun (map (ap FunArrow (typeSubst tam)) tys) `typeArrow` typeArrow dataty dataty'
    fm :: [Ast.DataCon] -> [(Var, (TypePat, (CVar, [Var], (Exp, Exp))))] 
    --                    (field, (type, cases@(c, v, (access, mutate))))
    fm cl = do
      (L _ c, fl) <- cl
      -- FIXME: check for duplicate names in fl
      let vfl = zip argvars fl
          vl = map fst vfl
          mf fv v 
            | v == fv = Apply (Var mutvar) (Var v)
            | otherwise = Var v
      (fv, Ast.DataField (Just (L fnl fn)) ft) <- vfl
      return (fn, (ft, (c, vl, 
        ( ExpLoc fnl (Var fv)
        , ExpLoc fnl $ foldl' Apply (Var c) $ map (mf fv) vl))))
    third f (a,b,c) = (a,b,f c)

  pattern' :: Map Var SrcLoc -> SrcLoc -> Ast.Pattern -> (Pattern, Map Var SrcLoc)
  pattern' s _ Ast.PatAny = (anyPat, s)
  pattern' s l (Ast.PatVar v)
    | Just l' <- Map.lookup v s = dupError v l l'
    | otherwise = (anyPat { patVars = [v] }, Map.insert v l s)
  pattern' s l (Ast.PatAs v p) 
    | Just l' <- Map.lookup v s = dupError v l l'
    | otherwise = first (addPatVar v) $ pattern' (Map.insert v l s) l p
  pattern' s l (Ast.PatSpec p t) = first (addPatSpec t) $ pattern' s l p
  pattern' s _ (Ast.PatLoc l p) = pattern' s l p
  pattern' s l (Ast.PatOps o) = pattern' s l (Ast.opsPattern l $ sortOps precs l o)
  pattern' s l (Ast.PatList apl) = (foldr (\p pl -> consPat (V ":") [p, pl]) (consPat (V "[]") []) pl, s') where
    (pl, s') = patterns' s l apl
  pattern' s l (Ast.PatCons c pl) = first (consPat c) $ patterns' s l pl
  pattern' s _ (Ast.PatInt i) = (anyPat { patCheck = Just (\v -> Prim (Binop IntEqOp) [Int i, Spec (Var v) typeInt]) }, s)
  pattern' s _ (Ast.PatChar c) = (anyPat { patCheck = Just (\v -> Prim (Binop ChrEqOp) [Char c, Spec (Var v) typeChar]) }, s)
  pattern' s l (Ast.PatString cl) = pattern' s l $ Ast.PatList $ map Ast.PatChar cl
  pattern' _ l (Ast.PatLambda _ _) = irError l $ quoted "->" <+> "(lambda) patterns not yet implemented"
  pattern' _ l (Ast.PatTrans t _) = irError l $ "cannot apply" <+> quoted t <+> "in pattern"

  patterns' :: Map Var SrcLoc -> SrcLoc -> [Ast.Pattern] -> ([Pattern], Map Var SrcLoc)
  patterns' s l = foldl' (\(pl,s) -> first ((pl ++).(:[])) . pattern' s l) ([],s)

  patterns :: SrcLoc -> [Ast.Pattern] -> ([Pattern], InScopeSet)
  patterns l = fmap Map.keysSet . patterns' Map.empty l

  listexpr :: (a -> Exp) -> [a] -> Exp
  listexpr f = foldr (Apply . Apply (Var $ V ":") . f) (Var $ V "[]")

  expr :: InScopeSet -> SrcLoc -> Ast.Exp -> Exp
  expr _ _ (Ast.Int i) = Int i
  expr _ _ (Ast.Char c) = Char c
  expr _ _ (Ast.String s) = listexpr Char s
  expr _ _ (Ast.Var v) = Var v
  expr s l (Ast.Lambda pl e) = lambdas s l pl e
  expr s l (Ast.Apply f args) = foldl' Apply (expr s l f) $ map (expr s l) args
  expr s l (Ast.Let st p e c) = doMatch letpat s l [st] (p,e,c)
  expr s l (Ast.Def f pl e ac) = Let False f (lambdas s l pl e) $ expr (Set.insert f s) l ac
  expr s l (Ast.Case st sl) = doMatch switches s l [st] sl
  expr s l (Ast.Ops o) = expr s l $ Ast.opsExp l $ sortOps precs l o
  expr s l (Ast.Spec e t) = Spec (expr s l e) t
  expr s l (Ast.List el) = listexpr (expr s l) el
  expr s l (Ast.If st c e1 e2) = Apply (Apply (Apply (Var (V (sStatic st "if"))) $ e c) $ e e1) $ e e2 where e = expr s l
  expr s _ (Ast.Seq q) = seq s q
  expr s _ (Ast.ExpLoc l e) = ExpLoc l $ expr s l e
  expr _ l a = irError l $ quoted a <+> "not allowed in expressions"

  seq :: InScopeSet -> [Loc Ast.Stmt] -> Exp
  seq _ [] = Var (V "()") -- only used when last is assignment; not a warning or error since "_ = ..." is sensible
  seq s [L l (Ast.StmtExp e)] = expr s l e
  seq s (L l (Ast.StmtExp e):q) = seq s (L l (Ast.StmtLet (Ast.PatCons (V "()") []) e):q)
  seq s (L l (Ast.StmtLet p e):q) = doMatch letpat s l [] (p,e,Ast.Seq q)
  seq s q@(L _ (Ast.StmtDef f _ _):_) = ExpLoc l $ Let False f body $ seq (Set.insert f s) rest where
    (L l body, rest) = funcases s f isfcase [] q -- TODO: local recursion (scope)
    isfcase (L l (Ast.StmtDef f' a b)) | f == f' = Just (L l (a,b))
    isfcase _ = Nothing

  funcases :: InScopeSet -> Var -> (a -> Maybe (Loc ([Ast.Pattern],Ast.Exp))) -> [Static] -> [a] -> (Loc Exp, [a])
  funcases s f isfdef st dl = (L l body, rest) where
    body = lambdacases s l n st (map unLoc defs)
    l = loc defs
    (defs,rest) = spanJust isfdef dl
    n = fromMaybe (irError l $ "equations for" <+> quoted f <+> "have different numbers of arguments") $ 
      unique $ map (length . fst . unLoc) defs

  -- |process a multi-argument lambda expression
  lambdas :: InScopeSet -> SrcLoc -> [Ast.Pattern] -> Ast.Exp -> Exp
  lambdas s loc p e = lambdacases s loc (length p) [] [(p,e)]

  -- |process a multi-argument multi-case function set
  lambdacases :: InScopeSet -> SrcLoc -> Int -> [Static] -> [([Ast.Pattern], Ast.Exp)] -> Exp
  lambdacases s loc n st arms = foldr Lambda body vl where
    (s',vl) = patsNames (s `Set.union` ps) n b
    ((ps,[b]),body) = matcher cases s' loc st (vl,arms)

  letpat :: InScopeSet -> SrcLoc -> (Ast.Pattern, Ast.Exp, Ast.Exp) -> (InScopeSet, [Switch])
  letpat s0 loc (p,e,c) = (ps, [Switch [e'] [CaseMatch p' id (CaseBody c')]]) where
    (p',ps) = patterns loc [p]
    e' = expr s0 loc e
    c' = expr (s0 `Set.union` ps) loc c

  cases :: InScopeSet -> SrcLoc -> ([Var], [([Ast.Pattern], Ast.Exp)]) -> (InScopeSet, [Switch])
  cases s0 loc (vals,arms) = second (\b -> [Switch (map Var vals) b]) $ mapss arm arms where
    arm (p,e) = (ps,CaseMatch p' id (CaseBody e')) where
      (p',ps) = patterns loc p
      e' = expr (s0 `Set.union` ps) loc e

  -- Convert all the patterns and expressions in a Case Switch list (but not the switches themselves) and collect all the pattern variables.
  switches :: InScopeSet -> SrcLoc -> [Ast.Switch] -> (InScopeSet, [Switch])
  switches s0 loc = switchs Set.empty where
    switchs s = mapss (switch s)
    switch s (e,c) = second (switchl e) $ caseline s c
    switchl e = Switch [expr s0 loc e]
    caseline s (Ast.CaseGuard r) = second ((:[]) . CaseMatch [consPat (V "True") []] id) $ casetail s r
    caseline s (Ast.CaseMatch ml) = mapss (casematch s) ml
    casematch s (p,r) = (s', CaseMatch p' id r') where 
      (p',ps) = patterns loc [p]
      (s',r') = casetail (s `Set.union` ps) r
    casetail s (Ast.CaseGroup st l) = second (CaseGroup st) $ switchs s l
    casetail s (Ast.CaseBody e) = (s, CaseBody $ expr (s0 `Set.union` s) loc e)

  doMatch :: (InScopeSet -> SrcLoc -> a -> (InScopeSet, [Switch])) -> InScopeSet -> SrcLoc -> [Static] -> a -> Exp
  doMatch f s l st = snd . matcher f s l st

  matcher :: (InScopeSet -> SrcLoc -> a -> (InScopeSet, [Switch])) -> InScopeSet -> SrcLoc -> [Static] -> a -> ((InScopeSet, [[[Pattern]]]), Exp)
  matcher f s l st x = ((s', map (map casePat . switchCases) y), match st (s `Set.union` s') y Nothing) where (s',y) = f s l x

  -- |match takes n unmatched expressions and a list of n-tuples (lists) of patterns, and
  -- iteratively reduces the list of possibilities by matching each expression in turn.  This is
  -- used to process the stack of unmatched patterns that build up as we expand constructors.
  --
  --   (1) partitioning the cases by outer element,
  --
  --   (2) performing the outer match, and
  --
  --   (3) iteratively matching the components returned in the outer match
  --
  -- Part (3) is handled by building up a stack of unprocessed expressions and an associated
  -- set of pattern stacks, and then iteratively reducing the set of possibilities.
  -- This generally follows Wadler's algorithm in The Implementation of Functional Programming Languages
  match :: [Static] -> InScopeSet -> [Switch] -> Maybe Exp -> Exp
  match = withFall . switch where
    -- process a list of sequental matches
    withFall :: (InScopeSet -> a -> Maybe Exp -> Exp) -> InScopeSet -> [a] -> Maybe Exp -> Exp
    withFall _ _ [] _ = error "withFall: empty list"
    withFall f s [x] fall = f s x fall
    withFall f s (x:l) fall = letf $ f s' x (Just callf) where
      (s',fv) = freshen s (V "fall")
      letf = Let False fv $ Lambda ignored $ withFall f s' l fall
      callf = Apply (Var fv) (Var $ V "()")

    switch :: [Static] -> InScopeSet -> Switch -> Maybe Exp -> Exp
    switch _ s (Switch [] alts) fall = withFall (\s ~(CaseMatch [] f e) -> f . matchTail s e) s alts fall
    switch [] s w fall = switch [False] s w fall
    switch st s (Switch (val:vals) alts) fall = letVarIf (head st) var val $ withFall (matchGroup st var vals) s' groups fall where
      -- separate into groups of vars vs. cons
      groups = groupBy ((==) `on` isJust . patCons . head . casePat) alts
      (s',var) = case unVar val of
        Just v -> (s,v)
        Nothing -> second head $ patsNames s 1 (map casePat alts)

    matchGroup :: [Static] -> Var -> [Exp] -> InScopeSet -> [Case] -> Maybe Exp -> Exp
    matchGroup ~(st:sts) var vals s group fall =
      case fst $ head alts of
        Nothing -> switch sts s (Switch vals (map snd alts)) fall
        Just _ -> Case st var (map cons alts') fall
      where
        alts = map (\(CaseMatch ~(p@(Pat{ patCons = c }):pl) f e) -> (c,CaseMatch pl (patLets st var p . f) (checknext p e))) group
        -- sort alternatives by toplevel tag (along with arity)
        alts' = groupPairs $
              map (\ ~(Just (c,cp), CaseMatch p pf pe) -> ((c,length cp), CaseMatch (cp++p) pf pe)) alts
        checknext (Pat{ patCheck = Just c }) e = CaseGroup st [Switch [c var] [CaseMatch [consPat (V "True") []] id e]]
        checknext _ e = e
        cons ((c,arity),alts) = (c,vl, switch (replicate arity st ++ sts) s' (Switch (map Var vl ++ vals) alts) fall) where
          (s',vl) = patsNames s arity (map casePat alts)

    matchTail :: InScopeSet -> CaseTail -> Maybe Exp -> Exp
    matchTail _ (CaseBody e) _ = e -- is Just fall a warning?
    matchTail s (CaseGroup st l) fall = match (repeat st) s l fall

-- Pretty printing

instance Pretty Decl where
  pretty' (LetD v e) =
    nestedPunct '=' v e
  pretty' (LetM vl e) =
    nestedPunct '=' (punctuate ',' vl) e
  pretty' (ExpD e) =
    pretty' e
  pretty' (Over v t e) =
    v <+> "::" <+> t $$
    nestedPunct '=' v e
  pretty' (Data t args cons) =
    pretty' $ Ast.Data t args $ map (second $ map $ Ast.DataField Nothing) cons

instance Pretty [Decl] where
  pretty' = vcat

instance Pretty Exp where
  pretty' (Spec e t) = 2 #> pguard 2 e <+> "::" <+> t
  pretty' (Let st v e body) = 1 #>
    sStatic st "let" <+> v <+> '=' <+> pretty e <+> "in" $$ pretty body
  pretty' (Case st v pl d) = 1 #>
    nested (sStatic st "case" <+> v <+> "of")
      (vcat (map arm pl ++ def d)) where
    arm (c, vl, e) = prettyop c vl <+> "->" <+> pretty e
    def Nothing = []
    def (Just e) = ["_ ->" <+> pretty e]
  pretty' (Int i) = pretty' i
  pretty' (Char c) = pretty' (show c)
  pretty' (Var v) = pretty' v
  pretty' (Lambda v e) = 1 #>
    v <+> "->" <+> pguard 1 e
  pretty' (Apply (Apply (Var (V ":")) h) t) | Just t' <- extract t =
    pretty' $ brackets $ 3 #> punctuate ',' (h : t') where
    extract (Var (V "[]")) = Just []
    extract (Apply (Apply (Var (V ":")) h) t) = (h :) <$> extract t
    extract _ = Nothing
  pretty' (Apply e1 e2) = uncurry prettyop (apply e1 [e2])
    where apply (Apply e a) al = apply e (a:al) 
          apply e al = (e,al)
  pretty' (Prim p el) = prettyop (V (primString p)) el
  pretty' (ExpLoc _ e) = pretty' e
  --pretty' (ExpLoc l e) = "{-@" <+> show l <+> "-}" <+> pretty' e
