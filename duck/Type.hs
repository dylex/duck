{-# LANGUAGE PatternGuards, MultiParamTypeClasses, FunctionalDependencies, UndecidableInstances, FlexibleInstances, TypeSynonymInstances, StandaloneDeriving #-}
-- | Duck Types

module Type
  ( TypeVal(..)
  , TypePat(..)
  , TypeFun(..)
  , IsType(..)
  , TypeEnv
  , Variance(..)
  , substVoid
  , singleton
  , unsingleton, unsingleton'
  , freeVars
  -- * Transformation annotations
  , Trans(..), TransType
  , argType
  ) where

import Data.Maybe
import qualified Data.List as List
import Data.Map (Map)
import qualified Data.Map as Map

import Util
import Pretty
import Var

-- |The type of type functions.  TyFun and TsFun below represent an
-- union of one or more of these primitive type functions.
--
-- Since type functions can be arbitrary functions from types to types,
-- there is no algorithmic way to simplify their intersections or unions.
-- Therefore, we represent them as a union of primitive type functions
-- (either arrow types or named closures).
--
-- In particular, we can perform the simplification when unioning @(a -> b)@
-- and @(c -> d)@ if @a@ and @c@ have a representable intersection.  We could have
-- chosen to make all intersections representable by storing intersections of
-- function types as well, but for now we still stick to storing unions.
data TypeFun t
  = FunArrow !t !t
  | FunClosure !Var ![t]

deriving instance Eq t => Eq (TypeFun t)
deriving instance Ord t => Ord (TypeFun t)
deriving instance Show t => Show (TypeFun t)

-- |A concrete type (the types of values are always concrete)
data TypeVal
  = TyCons !CVar [TypeVal]
  | TyFun ![TypeFun TypeVal]
  | TyVoid

deriving instance Eq TypeVal
deriving instance Ord TypeVal
deriving instance Show TypeVal

-- |A polymorphic set of concrete types (used for function overloads).  This is the same
-- as 'TypeVal' except that it can contain type variables.
data TypePat
  = TsVar !Var
  | TsCons !CVar [TypePat]
  | TsFun ![TypeFun TypePat]
  | TsVoid

deriving instance Eq TypePat
deriving instance Ord TypePat
deriving instance Show TypePat

type TypeEnv = Map Var TypeVal

-- |Variance of type constructor arguments.
--
-- Each type argument to a type constructor is treated as either covariant or
-- invariant.  A covariant argument occurs as concrete data, while an invariant
-- type appears as an argument to a function (or similar).  For example, in
--
-- >   data T a b = A a b (a -> Int)
--
-- @b@ is covariant but @a@ is invariant.  In terms of subtype relations, we get
--
-- >   T Int Void <= T Int Int   --   since Void <= Int
--
-- but not
--
-- >   T Void Int <= T Int Void  -- fails, since the first argument is invariant
--
-- For more explanation of covariance and invariance, see
--     <http://en.wikipedia.org/wiki/Covariance_and_contravariance_(computer_science)>
data Variance = Covariant | Invariant

-- |Possible kinds of type macro transformers.
data Trans
  = Delayed -- :: Delay
  deriving (Eq, Ord, Show)

type TransType t = (Maybe Trans, t)

instance HasVar TypePat where
  var = TsVar
  unVar (TsVar v) = Just v
  unVar _ = Nothing

class IsType t where
  typeCons :: CVar -> [t] -> t
  typeFun :: [TypeFun t] -> t
  typeVoid :: t

  unTypeCons :: t -> Maybe (CVar, [t])
  unTypeFun :: t -> Maybe [TypeFun t]

  typePat :: t -> TypePat

instance IsType TypeVal where
  typeCons = TyCons
  typeFun = TyFun
  typeVoid = TyVoid

  unTypeCons (TyCons c a) = Just (c,a)
  unTypeCons _ = Nothing
  unTypeFun (TyFun f) = Just f
  unTypeFun _ = Nothing

  typePat = singleton

instance IsType TypePat where
  typeCons = TsCons
  typeFun = TsFun
  typeVoid = TsVoid

  unTypeCons (TsCons c a) = Just (c,a)
  unTypeCons _ = Nothing
  unTypeFun (TsFun f) = Just f
  unTypeFun _ = Nothing

  typePat = id

-- |Type environment substitution
subst :: TypeEnv -> TypePat -> TypePat
subst env (TsVar v)
  | Just t <- Map.lookup v env = singleton t
  | otherwise = TsVar v
subst env (TsCons c tl) = TsCons c (map (subst env) tl)
subst env (TsFun f) = TsFun (map fun f) where
  fun (FunArrow s t) = FunArrow (subst env s) (subst env t)
  fun (FunClosure f tl) = FunClosure f (map (subst env) tl)
subst _ TsVoid = TsVoid
_subst = subst

-- |Type environment substitution with unbound type variables defaulting to void
substVoid :: TypeEnv -> TypePat -> TypeVal
substVoid env (TsVar v) = Map.findWithDefault TyVoid v env
substVoid env (TsCons c tl) = TyCons c (map (substVoid env) tl)
substVoid env (TsFun f) = TyFun (map fun f) where
  fun (FunArrow s t) = FunArrow (substVoid env s) (substVoid env t)
  fun (FunClosure f tl) = FunClosure f (map (substVoid env) tl)
substVoid _ TsVoid = TyVoid

-- |Occurs check
occurs :: TypeEnv -> Var -> TypePat -> Bool
occurs env v (TsVar v') | Just t <- Map.lookup v' env = occurs' v t
occurs _ v (TsVar v') = v == v'
occurs env v (TsCons _ tl) = any (occurs env v) tl
occurs env v (TsFun f) = any fun f where
  fun (FunArrow s t) = occurs env v s || occurs env v t
  fun (FunClosure _ tl) = any (occurs env v) tl
occurs _ _ TsVoid = False
_occurs = occurs

-- |Types contains no variables
occurs' :: Var -> TypeVal -> Bool
occurs' _ _ = False

-- |This way is easy
--
-- For convenience, we overload the singleton function a lot.
class Singleton a b | a -> b where
  singleton :: a -> b

instance Singleton TypeVal TypePat where
  singleton (TyCons c tl) = TsCons c (singleton tl)
  singleton (TyFun f) = TsFun (singleton f)
  singleton TyVoid = TsVoid

instance Singleton a b => Singleton [a] [b] where
  singleton = map singleton

instance Singleton a b => Singleton (TypeFun a) (TypeFun b) where
  singleton (FunArrow s t) = FunArrow (singleton s) (singleton t)
  singleton (FunClosure f tl) = FunClosure f (singleton tl)
 
-- TODO: I'm being extremely cavalier here and pretending that the space of
-- variables in TsCons and TsVar is disjoint.  When this fails in the future,
-- skolemize will need to be fixed to turn TsVar variables into fresh TyCons
-- variables.
_ignore = skolemize
skolemize :: TypePat -> TypeVal
skolemize (TsVar v) = TyCons v [] -- skolemization
skolemize (TsCons c tl) = TyCons c (map skolemize tl)
skolemize (TsFun f) = TyFun (map skolemizeFun f)
skolemize TsVoid = TyVoid

skolemizeFun :: TypeFun TypePat -> TypeFun TypeVal
skolemizeFun (FunArrow s t) = FunArrow (skolemize s) (skolemize t)
skolemizeFun (FunClosure f tl) = FunClosure f (map skolemize tl)

-- |Convert a singleton typeset to a type if possible
unsingleton :: TypePat -> Maybe TypeVal
unsingleton = unsingleton' Map.empty

unsingleton' :: TypeEnv -> TypePat -> Maybe TypeVal
unsingleton' env (TsVar v) | Just t <- Map.lookup v env = Just t
unsingleton' _ (TsVar _) = Nothing
unsingleton' env (TsCons c tl) = TyCons c =.< mapM (unsingleton' env) tl
unsingleton' env (TsFun f) = TyFun =.< mapM (unsingletonFun' env) f
unsingleton' _ TsVoid = Just TyVoid

unsingletonFun' :: TypeEnv -> TypeFun TypePat -> Maybe (TypeFun TypeVal)
unsingletonFun' env (FunArrow s t) = do
  s <- unsingleton' env s
  t <- unsingleton' env t
  return (FunArrow s t)
unsingletonFun' env (FunClosure f tl) = FunClosure f =.< mapM (unsingleton' env) tl

-- |Find the set of free variables in a typeset
freeVars :: TypePat -> [Var]
freeVars (TsVar v) = [v]
freeVars (TsCons _ tl) = concatMap freeVars tl
freeVars (TsFun fl) = concatMap f fl where
  f (FunArrow s t) = freeVars s ++ freeVars t
  f (FunClosure _ tl) = concatMap freeVars tl
freeVars TsVoid = []

-- |Apply a macro transformation to a type
transType :: IsType t => Trans -> t -> t
transType Delayed t = typeFun [FunArrow (typeCons (V "()") []) t]

-- |Converts an annotation argument type to the effective type of the argument within the function.
argType :: IsType t => TransType t -> t
argType (Nothing, t) = t
argType (Just c, t) = transType c t

-- Pretty printing

instance Pretty TypePat where
  pretty' (TsVar v) = pretty' v
  pretty' (TsCons t []) = pretty' t
  pretty' (TsCons t tl) | isTuple t = 3 #> punctuate ',' tl
  pretty' (TsCons t tl) = prettyap t tl
  pretty' (TsFun f) = pretty' f
  pretty' TsVoid = pretty' "Void"

instance Pretty TypeVal where
  pretty' = pretty' . singleton

instance Pretty t => Pretty (TypeFun t) where
  pretty' (FunClosure f []) = pretty' f
  pretty' (FunClosure f tl) = prettyap f tl
  pretty' (FunArrow s t) = 1 #> s <+> "->" <+> guard 1 t

instance Pretty t => Pretty [TypeFun t] where
  pretty' [f] = pretty' f
  pretty' fl = 5 #> punctuate '&' fl

instance (Pretty t, IsType t) => Pretty (TransType t) where
  pretty' (Nothing, t) = pretty' t
  pretty' (Just c, t) = prettyap (show c) [t]
