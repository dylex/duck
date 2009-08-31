{-# LANGUAGE RelaxedPolyRec #-}
-- | Duck prefix trie data structure
--
-- A prefix trie represents a partial map @[k] -> v@ with the property that no
-- key is a proper prefix of any other key.  This version additionaly maps
-- every non-empty prefix @[k] -> a@.
-- 
-- For example, a prefix trie can be used to represent the types of overloaded
-- curried functions.
--
-- In order to represent argument transformation macros, Ptries have an
-- additional field on each edge that describes something about that node.
-- This is the middle @a@ type argument to Ptrie.

module Ptrie
  ( Ptrie
  , empty
  , unLeaf
  , mapInsert
  , lookup
  , toList
  ) where

import Prelude hiding (lookup)
import Data.Map (Map)
import qualified Data.Map as Map

import Util

-- In order to make the representation canonical, the Maps in a Ptrie are never empty
data Ptrie k a v
  = Leaf !v
  | Node (Map k (a, Ptrie k a v))
  deriving (Eq)

-- |A very special Ptrie that is an exception to the nonempty rule.
empty :: Ptrie k a v
empty = Node Map.empty

unLeaf :: Ptrie k a v -> Maybe v
unLeaf (Node _) = Nothing
unLeaf (Leaf v) = Just v

singleton :: [(a,k)] -> v -> Ptrie k a v
singleton [] v = Leaf v
singleton ((a,x):k) v = Node (Map.singleton x (a, singleton k v))

-- |Insertion is purely destructive, both of existing prefixes of k and
-- of existing associated @a@ values.
insert :: Ord k => [(a,k)] -> v -> Ptrie k a v -> Ptrie k a v
insert [] v _ = Leaf v
insert ((a,x):k) v (Node m) = Node $ Map.insertWith (const $ (,) a . insert k v . snd) x (a, singleton k v) m
insert k v _ = singleton k v

mapInsert :: (Ord f, Ord k) => f -> [(a,k)] -> v -> Map f (Ptrie k a v) -> Map f (Ptrie k a v)
-- I'm so lazy
mapInsert f k v m = Map.insertWith (const $ insert k v) f (singleton k v) m

lookup :: Ord k => [k] -> Ptrie k a v -> ([a], Maybe (Ptrie k a v))
lookup [] t = ([], Just t)
lookup (_:_) (Leaf _) = ([], Nothing)
lookup (x:k) (Node t) = maybe ([], Nothing) (\(a,m) -> first (a:) $ lookup k m) $ Map.lookup x t

toList :: Ptrie k a v -> [([(a,k)],v)]
toList (Leaf v) = [([],v)]
toList (Node t) = [((a,x):k,v) | (x,(a,p)) <- Map.toList t, (k,v) <- toList p]
