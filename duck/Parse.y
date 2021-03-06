-- | Duck parser

{
{-# OPTIONS_GHC -w #-}

module Parse (lex, parse) where

import Data.Functor
import qualified Data.Map as Map
import Data.Monoid (mappend, mconcat)

import Util
import Pretty
import SrcLoc hiding (loc)
import Var hiding (unVar)
import Token
import ParseMonad
import ParseOps
import Lex
import Layout
import IrType
import Ast
import Prims hiding (typeArrow)

}

%name parse
%tokentype { Loc Token }

%monad { P }
%lexer { (layout lexer >>=) } { L _ TokEOF } -- Happy wants the lexer in continuation form
%error { parserError }

%token
  var  { L _ (TokVar _) }
  cvar { L _ (TokCVar _) }
  sym  { L _ (TokSym _) }
  csym { L _ (TokCSym _) }
  int  { L _ (TokInt _) }
  chr  { L _ (TokChar _) }
  str  { L _ (TokString _) }
  data { L _ (TokData) }
  let  { L _ (TokLet _) }
  in   { L _ (TokIn) }
  case { L _ (TokCase _) }
  of   { L _ (TokOf) }
  if   { L _ (TokIf _) }
  then { L _ (TokThen) }
  else { L _ (TokElse) }
  '='  { L _ (TokEq) }
  '::' { L _ (TokDColon) }
  ','  { L _ (TokComma) }
  '('  { L _ (TokLP) }
  ')'  { L _ (TokRP) }
  '['  { L _ (TokLB) }
  ']'  { L _ (TokRB) }
  '{'  { L _ (TokLC _) }
  '}'  { L _ (TokRC _) }
  ';'  { L _ (TokSemi _) }
  '_'  { L _ (TokAny) }
  '\\' { L _ (TokGroup) }
  '->' { L _ (TokArrow) }
  '-'  { L _ (TokMinus) }
  import { L _ (TokImport) }
  infix  { L _ (TokInfix _) }

%%

--- Toplevel stuff ---

prog :: { Prog }
  : {--} { [] }
  | '{' decls '}' { concat $ reverse $2 }

decls :: { [[Loc Decl]] }
  : {--} { [] }
  | decl { [$1] }
  | decls ';' { $1 }
  | decls ';' decl { $3 : $1 }

decl :: { [Loc Decl] }
  : exp { [declExp $1] }
  | exp '=' exp {% lefthandside $1 >.= \l -> [loc $1 $> $ either (\p -> LetD p (expLoc $3)) (\ (v,pl) -> DefD v pl (expLoc $3)) l] }
  | import var { [loc $1 $> $ Import (var $2)] }
  | infix int asyms { [loc $1 $> $ Infix (int $2,ifix $1) (reverse (unLoc $3))] }
  | data dvar lvars maybeConstructors { [loc $1 $> $ Data $2 (reverse (unLoc $3)) (reverse (unLoc $4))] }

maybeConstructors :: { Loc [DataCon] }
  : {--} { loc0 [] }
  | of '{' constructors '}' { loc $1 $> $ $3 }

constructors :: { [DataCon] }
  : constructor { [$1] }
  | constructors ';'  constructor { $3 : $1 }

constructor :: { DataCon }
  : exp3(atom) {% constructor $1 }

--- Expressions ---

-- The underscored atom_ means it cannot contain a parenthesis-killing backslash expression.

-- read "negative one": must be parenthesized
exp_1 :: { Loc Exp }
  : lvar '=' exp_1 { loc $1 $> $ Equals (unLoc $1) (expLoc $3) }
  | exp { $1 }

exp :: { Loc Exp }
  : exp0(atom) { $1 }

exp0(a) :: { Loc Exp }
  : exp0(atom_) '::' exp1(a) {% ty $3 >.= \t -> loc $1 $> $ Spec (expLoc $1) (unLoc t) }
  | exp1(a) { $1 }

exp1(a) :: { Loc Exp }
  : arrows(a) {% arrows $1 }

stmts :: { [Loc Stmt] }
  : stmt { [$1] }
  | stmts ';' stmt { $3 : $1 }

stmt :: { Loc Stmt }
  : exp { loc1 $1 $ StmtExp (expLoc $1) }
  | exp '=' exp {% lefthandside $1 >.= loc $1 $> . either (\p -> StmtLet p (expLoc $3)) (\(v,pl) -> StmtDef (unLoc v) pl (expLoc $3)) }

arrows(a) :: { Loc (Stack Exp Exp) }
  : notarrow(a) { loc1 $1 (Base (expLoc $1)) }
  | exp2(atom_) '->' arrows(a) { loc $1 $> (expLoc $1 :. unLoc $3) }

notarrow(a) :: { Loc Exp }
  : let exp '=' exp in exp1(a) {% lefthandside $2 >.= \l -> loc $1 $> $ either (\p -> Let (tokStatic (unLoc $1)) p (expLoc $4) (expLoc $6)) (\ (v,pl) -> Def (unLoc v) pl (expLoc $4) (expLoc $6)) l }
  | case caseblock(a) { loc $1 $> $ Case (tokStatic (unLoc $1)) (unLoc $2) }
  | if exp then exp else exp1(a) { loc $1 $> $ If (tokStatic (unLoc $1)) (expLoc $2) (expLoc $4) (expLoc $6) }
  | '{' stmts '}' { loc $1 $> $ Seq (reverse $2) }
  | exp2(a) { $1 }

caseblock(a) :: { Loc [(Exp, Case)] }
  : switch(a) { fmap (:[]) $1 }
  | '{' switches '}' { loc $1 $> $ reverse $2 }

switches :: { [(Exp, Case)] }
  : switch(atom) { [unLoc $1] }
  | switches ';' switch(atom) { unLoc $3 : $1 }

switch(a) :: { Loc (Exp, Case) }
  : exp2(atom_) of '{' cases '}' { loc $1 $> $ (expLoc $1, CaseMatch (reverse $4)) }
  | exp2(atom_) casetail(a) { loc $1 $> $ (expLoc $1, CaseGuard (unLoc $2)) }

cases :: { [(Pattern,CaseTail)] }
  : casematch { [$1] }
  | cases ';' casematch { $3 : $1 }

casematch :: { (Pattern,CaseTail) }
  : exp2(atom_) casetail(atom) {% pattern $1 >.= \p -> (patLoc p, unLoc $2) }

casetail(a) :: { Loc CaseTail }
  : '->' exp1(a) { loc $1 $> $ CaseBody (expLoc $2) }
  | case caseblock(a) { loc $1 $> $ CaseGroup (tokStatic (unLoc $1)) (unLoc $2) }

exp2(a) :: { Loc Exp }
  : commas(a) { fmap tuple $1 }

commas(a) :: { Loc [Exp] }
  : exp3(a) { loc1 $1 [expLoc $1] }
  | commas(atom_) ',' exp3(a) { loc $1 $> $ expLoc $3 : unLoc $1 }

exp3(a) :: { Loc Exp }
  : ops(a) { fmap ops $1 }

ops(a) :: { Loc (Ops Exp) }
  : ops(atom_) asym unops(a) { loc $1 $> $ OpBin (unLoc $2) (unLoc $1) (unLoc $3) }
  | unops(a) { $1 }

unops(a) :: { Loc (Ops Exp) }
  : exp4(a) { loc1 $1 $ OpAtom (expLoc $1) }
  | '-' unops(a) { loc $1 $> $ OpUn (V "-") (unLoc $2) }

exp4(a) :: { Loc Exp }
  : exps(a) { fmap apply $1 }

exps(a) :: { Loc [Exp] }
  : a { fmap (:[]) $1 }
  | exps(atom_) a { loc $1 $> $ expLoc $2 : unLoc $1 }

atom :: { Loc Exp }
  : atom_ { $1 }
  | '\\' exp { loc $1 $> (expLoc $2) }

atom_ :: { Loc Exp }
  : int { fmap (Int . tokInt) $1 }
  | chr { fmap (Char . tokChar) $1 }
  | str { fmap (String . tokString) $1 }
  | lvar { fmap Var $1 }
  | cvar { fmap Var $ locVar $1 }
  | '_' { loc1 $1 Any }
  | '(' exp_1 ')' { $2 }
  | '(' exp_1 error {% unmatched $1 }
  | '(' ')' { loc $1 $> $ Var (V "()") }
  | '[' ']' { loc $1 $> $ Var (V "[]") }
  | '[' commas(atom) ']' { loc $1 $> $ List (reverse (unLoc $2)) }
  | '[' commas(atom) error {% unmatched $1 }

--- Variables ---

lvar :: { Loc Var }
  : var { locVar $1 }
  | '(' sym ')' { loc $1 $> (var $2) }
  | '(' '-' ')' { loc $1 $> (V "-") }
  | '(' if ')' { loc $1 $> (V $ sStatic (tokStatic (unLoc $2)) "if") }

lvars :: { Loc [Var] }
  : {--} { loc0 [] }
  | lvars var { loc $1 $> $ var $2 : unLoc $1 }

dvar :: { Loc Var }
  : cvar { locVar $1 }
  | '(' ')' { loc $1 $> $ V "()" } -- type ()

asym :: { Loc Var }
  : sym { locVar $1 }
  | csym { locVar $1 }
  | '-' { loc1 $1 $ V "-" }

asyms :: { Loc [Var] }
  : asym { fmap (:[]) $1 }
  | asyms asym { loc $1 $> $ unLoc $2 : unLoc $1 }

{

parse :: P Prog

parserError :: Loc Token -> P a
parserError (L l t) = parseError l ("syntax error "++showAt t)

unmatched :: Loc Token -> P a
unmatched (L l t) = parseError l $ "unmatched" <+> quoted t

tscons :: CVar -> [TypePat] -> TypePat
tscons (V "Void") [] = TsVoid
tscons c args = TsCons c args

var :: Loc Token -> Var
var = tokVar . unLoc

int :: Loc Token -> Int
int = tokInt . unLoc

ifix :: Loc Token -> Fixity
ifix = tokFix . unLoc

loc :: Loc x -> Loc y -> a -> Loc a
loc (L l _) (L r _) = L (mappend l r)

loc1 :: Loc x -> a -> Loc a
loc1 (L l _) = L l

loc0 :: a -> Loc a
loc0 = L noLoc

locVar :: Loc Token -> Loc Var
locVar = fmap tokVar

expLoc :: Loc Exp -> Exp
expLoc (L l (ExpLoc _ e)) = expLoc (L l e) -- shouldn't happen
expLoc (L l e)
  | hasLoc l = ExpLoc l e
  | otherwise = e

patLoc :: Loc Pattern -> Pattern
patLoc (L l (PatLoc _ e)) = patLoc (L l e) -- shouldn't happen
patLoc (L l p)
  | hasLoc l = PatLoc l p
  | otherwise = p

apply :: [Exp] -> Exp
apply [] = undefined
apply [e] = e
apply el | f:args <- reverse el = Apply f args

tuple :: [Exp] -> Exp
tuple [e] = e
tuple el = Apply (Var (tupleCons el)) (reverse el)

ops :: Ops Exp -> Exp
ops (OpAtom e) = e
ops o = Ops o

pattern :: Loc Exp -> P (Loc Pattern)
pattern (L l e) = L l <$> patternExp l e

patterns :: Loc [Exp] -> P (Loc [Pattern])
patterns (L l el) = L l <$> mapM (patternExp l) el

arrows :: Loc (Stack Exp Exp) -> P (Loc Exp)
arrows (L l stack) = case splitStack stack of
  ([],e) -> return $ L l e
  (el,e) -> patterns (L l el) >.= fmap (\pl -> Lambda pl e)

patternExp :: SrcLoc -> Exp -> P Pattern
patternExp l (Apply e el)  | Just (L _ c) <- unVar l e, isCons c = PatCons c <$> mapM (patternExp l) el
patternExp l (Apply f [e]) | Just (L _ t) <- unVar l f = PatTrans t <$> patternExp l e
patternExp l (Apply e _) = parseError l $ "only constructors and transforms can be applied here, not" <+> quoted e
patternExp l (Var c) | isCons c = return $ PatCons c []
patternExp l (Var v) = return $ PatVar v
patternExp l Any = return PatAny
patternExp l (Int i) = return $ PatInt i
patternExp l (Char c) = return $ PatChar c
patternExp l (String s) = return $ PatString s
patternExp l (List el) = PatList <$> mapM (patternExp l) el
patternExp l (Ops ops) = PatOps <$> patternOps l ops
patternExp l (Equals v e) = patternExp l e >.= PatAs v
patternExp l (Spec e t) = patternExp l e >.= \p -> PatSpec p t
patternExp l (Lambda pl e) = PatLambda pl <$> patternExp l e
patternExp _ (ExpLoc l e) = PatLoc l <$> patternExp l e
patternExp l e = parseError l $ expTypeDesc e <+> "expression not allowed here"

patternOps :: SrcLoc -> Ops Exp -> P (Ops Pattern)
patternOps l (OpAtom e) = OpAtom <$> patternExp l e
patternOps l (OpBin v o1 o2) | isCons v = do
  p1 <- patternOps l o1
  p2 <- patternOps l o2
  return $ OpBin v p1 p2
patternOps l (OpBin v _ _) = parseError l $ "only constructor operators are allowed here, not" <+> quoted v
patternOps l (OpUn v _) = parseError l $ "unary operator" <+> quoted v <+> "not allowed here"

ty :: Loc Exp -> P (Loc TypePat)
ty (L l e) = L l <$> typeExp l e

tys :: Loc [Exp] -> P (Loc [TypePat])
tys (L l el) = L l <$> mapM (typeExp l) el

typeExp :: SrcLoc -> Exp -> P TypePat
typeExp l (Apply e el)  | Just (L _ c) <- unVar l e, isCons c = tscons c <$> mapM (typeExp l) el
typeExp l (Apply f [e]) | Just (L _ t) <- unVar l f = TsTrans t <$> typeExp l e
typeExp l (Apply e _) = parseError l ("only constructors and transforms can be applied in types, not" <+> quoted e)
typeExp l (Var c) | isCons c = return $ tscons c []
typeExp l (Var v) = return $ TsVar v
typeExp l (Lambda pl e) = do
  tl <- mapM (typePat l) pl
  t <- typeExp l e 
  return $ foldr typeArrow t tl
typeExp _ (ExpLoc l e) = typeExp l e
typeExp l (Int _) = parseError l ("integer types aren't implemented yet")
typeExp l Any = parseError l ("'_' isn't implemented for types yet")
typeExp l e = parseError l $ expTypeDesc e <+> "expression not allowed in type"

typePat :: SrcLoc -> Pattern -> P TypePat
typePat l (PatCons c pl) = tscons c <$> mapM (typePat l) pl
typePat l (PatVar v) = return $ TsVar v
typePat l (PatLambda pl p) = do
  tl <- mapM (typePat l) pl
  t <- typePat l p 
  return $ foldr typeArrow t tl
typePat l (PatTrans t p) = TsTrans t <$> typePat l p
typePat _ (PatLoc l p) = typePat l p
typePat l PatAny = parseError l ("'_' isn't implemented for types yet")
typePat l p = parseError l $ patTypeDesc p <+> "expression not allowed in type"

-- Reparse an expression on the left side of an '=' into either a pattern
-- (for a let) or a function declaraction (for a def).
lefthandside :: Loc Exp -> P (Either Pattern (Loc Var, [Pattern]))
lefthandside (L _ (ExpLoc l e)) = lefthandside (L l e)
lefthandside (L l (Apply e el)) | Just v <- unVar l e, not (isCons (unLoc v)) = do
  pl <- mapM (patternExp l) el
  return $ Right (v,pl)
lefthandside (L l (Ops (OpBin v o1 o2))) | not (isCons v) = do
  p1 <- patternOps l o1
  p2 <- patternOps l o2
  return $ Right (L l v, map PatOps [p1,p2])
lefthandside (L l p) = Left . patLoc . L l <$> patternExp l p

unVar :: SrcLoc -> Exp -> Maybe (Loc Var)
unVar l (Var v) = Just (L l v)
unVar _ (ExpLoc l e) = unVar l e
unVar _ _ = Nothing

-- Currently, specifications are only allowed to be single lowercase variables
spec :: Loc Exp -> P (Loc Var)
spec (L l e) | Just v <- unVar l e = return v
spec (L l e) = parseError l ("only variables are allowed in top level type specifications, not" <+> quoted e)

fieldExp :: SrcLoc -> Exp -> P DataField
fieldExp _ (ExpLoc l e) = fieldExp l e
fieldExp l (Spec e t) | Just f <- unVar l e, not (isCons (unLoc f)) = return $ DataField (Just f) t
fieldExp l t = DataField Nothing <$> typeExp l t

-- Reparse an expression into a constructor
constructor :: Loc Exp -> P DataCon
constructor (L _ (ExpLoc l e)) = constructor (L l e)
constructor (L l e) | Just v <- unVar l e, isCons (unLoc v) = return (v,[])
constructor (L l (Apply e el)) | Just v <- unVar l e, isCons (unLoc v) = do
  tl <- mapM (fieldExp l) el
  return (v,tl)
constructor (L l (Ops (OpBin v (OpAtom e1) (OpAtom e2)))) | isCons v = do
  t1 <- fieldExp l e1
  t2 <- fieldExp l e2
  return (L l v,[t1,t2])
constructor (L l e) = parseError l ("invalid constructor expression" <+> quoted e <+> "(must be <constructor> <args>... or equivalent)")

-- Turn an expression into a type specification decl if possible, or a bare expression decl otherwise
declExp :: Loc Exp -> Loc Decl
declExp (L l (Spec (ExpLoc lv (Var v)) t)) = L l (SpecD (L lv v) t)
declExp (L l e) = L l (ExpD e)

}
