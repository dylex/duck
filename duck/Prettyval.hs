{-# LANGUAGE PatternGuards, TypeSynonymInstances, FlexibleInstances, StandaloneDeriving #-}
{-# OPTIONS -fno-warn-orphans #-}
-- | Pretty printing for duck values and Lir

module Prettyval
  ( prettyval
  ) where

import Prelude hiding (lookup)
import Data.Map (Map)
import qualified Data.Map as Map

import Var
import Type
import Prims
import Pretty
import ParseOps
import SrcLoc
import Memory
import Value
import Lir
import qualified Ptrie

-- | Pretty printing for values

prettyval :: TypeVal -> Value -> Doc'
prettyval t v | t == typeInt = pretty' (unsafeUnvalue v :: Int)
prettyval t v | t == typeChar = pretty' (unsafeUnvalue v :: Char)
prettyval (TyCons d [t]) v | V "List" == dataName d = pretty' $
  brackets $ 3 #> punctuate ',' (map (prettyval t) v')
  where v' = unsafeUnvalue v :: [Value]
prettyval (TyFun _) v 
  | ValClosure v types args <- unsafeUnvalue v
  = prettyop v (zipWith prettyval types args)
prettyval (TyCons d [t]) v
  | d == datatypeType = pretty' t
  | d == datatypeIO = prettyio t (unsafeUnvalue v :: IOValue)
  | d == datatypeDelay, ValDelay e _ <- unsafeUnvalue v = prettyop "delay" [e]
prettyval (TyCons d args) v = prettyop c (zipWith prettyval tl' values) where
  (L _ c,tl) = dataConses d !! unsafeTag v
  tenv = Map.fromList (zip (dataTyVars d) args)
  tl' = map (substVoid tenv) tl
  values = unsafeUnvalConsN (length tl) v
prettyval TyVoid _ = error "found an impossible Void value in prettyval"

instance Pretty (TypeVal, Value) where
  pretty' (t,v) = 2 #> prettyval t v <+> "::" <+> t

prettyio :: TypeVal -> IOValue -> Doc'
prettyio t (ValLiftIO v) = pretty' (t,v)
prettyio _ (ValPrimIO p []) = pretty' $ primString p
prettyio _ (ValPrimIO IOPutChar [c]) = prettyop (V "ioPutChar") [prettyval typeChar c]
prettyio _ (ValBindIO v t d e _) = 0 #> v <+> "<-" <+> prettyio t d $$ pretty e
prettyio _ (ValPrimIO _ _) = pretty' "<unknown-prim-io>"

instance (Ord k, Pretty k) => Pretty (Map k TypeVal, Map k Value) where
  pretty' (t,v) = pretty' $ Map.intersectionWith (,) t v

-- Pretty printing for Lir

instance Pretty Prog where
  pretty' prog = vcat $
       [pretty "-- datatypes"]
    ++ [datatype (dataName d) (dataTyVars d) (dataConses d) 0 | d <- Map.elems (progDatatypes prog)]
    ++ [pretty "-- functions"]
    ++ [pretty $ function v o | (v,os) <- Map.toList (progFunctions prog), o <- os]
    ++ [pretty "-- overloads"]
    ++ [pretty (progOverloads prog)]
    ++ [pretty "-- definitions"]
    ++ [pretty $ definition d | d <- progDefinitions prog]
    where
    function v o = nested (v <+> "::") o
    definition (Def vl e) = nestedPunct '=' (punctuate ',' vl) e
    datatype t args [] =
      "data" <+> prettyap t args
    datatype t args l =
      nested ("data" <+> prettyap t args <+> "of") $
        vcat $ map (\(c,args) -> prettyop c args) l

instance Pretty (Map Var Overloads) where
  pretty' info = vcat [pr f tl o | (f,p) <- Map.toList info, (tl,o) <- Ptrie.toList p] where
    pr f tl o = nested (f <+> "::") (o{ overArgs = tl })

instance (IsType t, Pretty t) => Pretty (Overload t) where
  pretty' (Over _ a r _ Nothing) = 1 #> hsep (map (<+> "->") a) <+> r
  pretty' o@(Over _ _ _ v (Just e)) = sep [pretty' o{ overBody = Nothing },
    '=' <+> (1 #> hsep (map (<+> "->") v)) <+> e]

instance Pretty Exp where
  pretty' (ExpSpec e t) = 2 #> guard 2 e <+> "::" <+> t
  pretty' (ExpLet v e body) = 1 #>
    "let" <+> v <+> '=' <+> pretty e <+> "in" $$ pretty body
  pretty' (ExpCase v pl d) = 1 #>
    nested ("case" <+> v <+> "of")
      (vcat (map arm pl ++ def d)) where
    arm (c, vl, e) = prettyop c vl <+> "->" <+> pretty e
    def Nothing = []
    def (Just e) = ["_ ->" <+> pretty e]
  pretty' (ExpAtom a) = pretty' a
  pretty' (ExpApply e1 e2) = uncurry prettyop (apply e1 [e2])
    where apply (ExpApply e a) al = apply e (a:al)
          apply e al = (e,al)
  pretty' (ExpCons d c args) = prettyop (fst $ dataConses d !! c) args
  pretty' (ExpPrim p el) = prettyop (V (primString p)) el
  pretty' (ExpBind v e1 e2) = 0 #>
    v <+> "<-" <+> e1 $$ e2
  pretty' (ExpReturn e) = prettyap "return" [e]
  pretty' (ExpLoc _ e) = pretty' e
  --pretty' (ExpLoc l e) = "{-@" <+> show l <+> "-}" <+> pretty' e

instance Pretty Atom where
  pretty' (AtomLocal v) = pretty' v
  pretty' (AtomGlobal v) = pretty' v
  pretty' (AtomVal t v) = prettyval t v
