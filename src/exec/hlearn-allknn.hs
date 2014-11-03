{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ConstraintKinds #-}

import Control.DeepSeq
import Control.Monad
import Data.Csv hiding (Field)
import Data.List hiding (concat)
import Data.Maybe
import qualified Data.Map.Strict as Map
-- import qualified Data.HashMap.Strict as Map
import qualified Data.Params as P
import Data.Params.Vector
import Data.Params.PseudoPrim
import qualified Data.Params.Vector.Unboxed as VPU
import qualified Data.Vector as V
import qualified Data.Vector.Mutable as VM
import qualified Data.Vector.Generic as VG
import qualified Data.Vector.Generic.Mutable as VGM
import qualified Data.Vector.Unboxed as VU
import qualified Data.Vector.Unboxed.Mutable as VUM
import qualified Data.Vector.Primitive as VP
import qualified Data.Vector.Primitive.Mutable as VPM
import qualified Data.Vector.Storable as VS
import qualified Data.Vector.Storable.Mutable as VSM
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.Vector.Algorithms.Intro as Intro
import Numeric
import System.Console.CmdArgs.Implicit
import System.IO

import Test.QuickCheck hiding (verbose,sample)
import Control.Parallel.Strategies

import qualified Control.ConstraintKinds as CK
import qualified Prelude as P

import SubHask
import SubHask.Algebra.Vector

import HLearn.DataStructures.SpaceTree
import HLearn.DataStructures.SpaceTree.CoverTree hiding (head,tail)
import HLearn.DataStructures.SpaceTree.Algorithms.NearestNeighbor
import HLearn.Metrics.Lebesgue
import HLearn.Metrics.String
import HLearn.Models.Distributions.Common
import HLearn.Models.Distributions.Univariate.Normal
-- import HLearn.Metrics.Mahalanobis
-- import HLearn.Metrics.Mahalanobis.Normal
-- import HLearn.Models.Distributions

import Data.Params

import Paths_HLearn
import Data.Version

import LoadData
import Timing
import HLearn.UnsafeVector

type DP = L2 VU.Vector Float
type Tree = Maybe' (CoverTree_ (13/10) Array UnboxedArray DP)

unUnit (Just' a) = a

-------------------------------------------------------------------------------
-- command line parameters

data Params = Params
    { k                 :: Int
    , kForceSlow        :: Bool

    , reference_file    :: Maybe String
    , query_file        :: Maybe String
    , distances_file    :: String
    , neighbors_file    :: String

    , train_sequential  :: Bool
    , train_monoid      :: Bool
    , adopt_children    :: Bool
    , cache_dists       :: Bool
    , pca_data          :: Bool
    , varshift_data     :: Bool
    , searchEpsilon     :: Float

    , packMethod        :: PackMethod
    , sortMethod        :: SortMethod

    , verbose           :: Bool
    , debug             :: Bool
    }
    deriving (Show, Data, Typeable)

data PackMethod
    = NoPack
    | PackCT
    | PackCT2
    | PackCT3
    | SetLeaves
    deriving (Read,Show,Data,Typeable)

data SortMethod
    = NoSort
    | NumDP_Distance
    | NumDP_Distance'
    | Distance_NumDP
    | Distance_NumDP'
    deriving (Read,Show,Data,Typeable)

allknnParams = Params
    { k              = 1
                    &= help "Number of nearest neighbors to find"

    , reference_file = def
                    &= help "Reference data set in CSV format"
                    &= typFile

    , query_file     = def
                    &= help "Query data set in CSV format"
                    &= typFile

    , distances_file = "distances_hlearn.csv"
                    &= help "File to output distances into"
                    &= typFile

    , neighbors_file = "neighbors_hlearn.csv"
                    &= help "File to output the neighbors into"
                    &= typFile

    , searchEpsilon   = 0
                    &= help ""
                    &= groupname "Approximations"

    , packMethod     = PackCT
--     , packMethod     = NoPack
                    &= help "Specifies which method to use for cache layout of the covertree"
                    &= groupname "Tree structure optimizations"

    , sortMethod     = NumDP_Distance
--     , sortMethod     = NoSort
                    &= help "What order should the children be sorted in?"

    , kForceSlow     = False
                    &= help "Don't use precompiled k function; use the generic one"

    , train_sequential = False
                    &= help "don't train the tree in parallel; this may *slightly* speed up the nearest neighbor search at the expense of greatly slowing tree construction"

    , train_monoid   = False
                    &= help "train using the (asymptotically faster, but in practice slower) monoid algorithm"

    , adopt_children = True
                    &= help "move children to uncle nodes when they're closer than parents"

    , cache_dists    = True
                    &= help "pre-calculate the maximum distance from any node dp to all of its descendents; speeds up queries at the expense of O(n log n) overhead in construction"

    , pca_data       = False
                    &= groupname "Data Preprocessing"
                    &= help "Rotate the data points using the PCA transform.  Speeds up nearest neighbor searches, but computing the PCA can be expensive in many dimensions."
                    &= name "pca"
                    &= explicit

    , varshift_data  = False
                    &= help "Sort the attributes according to their variance.  Provides almost as much speed up as the PCA transform during neighbor searches, but much less expensive in higher dimensions."
                    &= name "varshift"
                    &= explicit

    , verbose        = False
                    &= help "Print tree statistics (takes some extra time)"
                    &= groupname "Debugging"

    , debug          = False
                    &= help "Test created trees for validity (takes lots of time)"
                    &= name "runtests"
                    &= explicit
    }
    &= summary ("HLearn k-nearest neighbor, version " ++ showVersion version)

-------------------------------------------------------------------------------
-- main

main = do
    -- cmd line args
    params <- cmdArgs allknnParams

    let checkfail x t = if x then error t else return ()
    checkfail (reference_file params == Nothing) "must specify a reference file"
    checkfail (searchEpsilon params < 0) "search epsilon must be >= 0"

    -- load datafile
    let filepath = fromJust $ reference_file params


    let l2nl=Proxy::Proxy (NeighborList (Static 1) (L2 UnboxedVector Float))
        l2ct=Proxy::Proxy (Maybe' (CoverTree_ (13/10) Array UnboxedArray (L2 UnboxedVector Float)))
    when (take 4 (reverse filepath) == "vsc.") $ do
        let dataparams = DataParams
                { datafile = filepath
                , labelcol = Nothing
                , pca      = pca_data params
                , varshift = varshift_data params
                }
        rs <- loaddata dataparams
        runit params rs l2ct l2nl

    let bownl=Proxy::Proxy (NeighborList (Static 1) (IndexedVector Int Float))
        bowct=Proxy::Proxy (Maybe' (CoverTree_ (13/10) Array Array (IndexedVector Int Float)))
    when ("docword" `isInfixOf` filepath) $ do
        let dataparams = DataParams
        rs <- loadBagOfWords filepath
        timeIO "loading data" $ return rs
        runit params rs bowct bownl

    let wordsnl=Proxy::Proxy (NeighborList (Static 1) (Lexical (Levenshtein (UnboxedArray Char))))
        wordsct=Proxy::Proxy (Maybe' (CoverTree_ (13/10) Array Array (Lexical (Levenshtein (UnboxedArray Char)))))
    when ("vocab" `isInfixOf` filepath) $ do
        let dataparams = DataParams
        rs <- loadWords filepath
        timeIO "loading data" $ return rs
        runit params rs wordsct wordsnl

--     runit params (undefined :: Tree) (undefined :: NeighborList (Static 1) DP)
--     if kForceSlow params || k params > 3
--         then do
--             putStrLn "WARNING: using slow version of k"
--             apWith1Param'
--                 (undefined :: NeighborList RunTime DP)
--                 _k
--                 (k params)
--                 (runit params (undefined::Tree))
--                 (undefined :: NeighborList RunTime DP)
--         else case k params of
--             1 -> runit params (undefined :: Tree) (undefined :: NeighborList (Static 1) DP)
--             2 -> runit params (undefined :: Tree) (undefined :: NeighborList (Static 2) DP)
--             3 -> runit params (undefined :: Tree) (undefined :: NeighborList (Static 3) DP)
--             4 -> runit params (undefined :: Tree) (undefined :: NeighborList (Static 4) DP)
--             5 -> runit params (undefined :: Tree) (undefined :: NeighborList (Static 5) DP)
--             100 -> runit params (undefined :: Tree) (undefined :: NeighborList (Static 100) DP)

-- {-# SPECIALIZE runit :: Params -> Tree -> NeighborList (Static 1) DP -> IO () #-}
-- {-# SPECIALIZE runit :: Params -> Tree -> NeighborList (Static 2) DP -> IO () #-}
-- {-# SPECIALIZE runit :: Params -> Tree -> NeighborList (Static 3) DP -> IO () #-}
-- {-# SPECIALIZE runit :: Params -> Tree -> NeighborList (Static 4) DP -> IO () #-}
-- {-# SPECIALIZE runit :: Params -> Tree -> NeighborList (Static 5) DP -> IO () #-}
-- {-# SPECIALIZE runit :: Params -> Tree -> NeighborList (Static 100) DP -> IO () #-}
-- {-# SPECIALIZE runit :: Param_k (NeighborList RunTime DP) => Params -> Tree -> NeighborList RunTime DP -> IO ()#-}

-- {-# INLINE runit #-}
runit :: forall k tree base childContainer nodeVvec dp ring proxy1 proxy2.
    ( MetricSpace dp
    , ViewParam Param_k (NeighborList k dp)
    , Show dp
    , Show (Scalar dp)
    , NFData dp
    , NFData (Scalar dp)
    , NFData (nodeVvec dp)
    , NFData (childContainer dp)
    , Field (Scalar dp)
    , VU.Unbox (Scalar dp)
    , tree ~ Maybe' (CoverTree_ base childContainer nodeVvec dp)
    , childContainer ~ Array
    , dp ~ Elem (nodeVvec dp)
    , Scalar (nodeVvec dp) ~ Int
    , Scalar dp ~ Float
    , MinBound (Scalar dp)
    , QuotientField (Scalar dp) Int
    , ValidNeighbor dp
    , KnownFrac base
    , Foldable (nodeVvec dp)
    , VG.Vector nodeVvec dp
    , VG.Vector childContainer tree
    , VG.Vector nodeVvec (Scalar dp)
    , Ord dp
    ) => Params
      -> Array dp
      -> proxy1 tree
      -> proxy2 (NeighborList k dp)
--       -> (dp -> dp')
      -> IO ()
runit params rs tree knn = do

    let dataparams = DataParams
            { datafile = fromJust $ reference_file params
            , labelcol = Nothing
            , pca      = pca_data params
            , varshift = varshift_data params
            }

    let reftree = setMaxDescendentDistance $ unUnit (
--             ( if train_sequential params then id else parallel )
--             ( if train_monoid params then trainMonoid else trainInsert )
            trainInsert
            rs :: tree )
    timeIO "building reference tree" $ return reftree

    let reftree_adopt = if adopt_children params
            then ctAdoptNodes reftree
            else reftree
    timeIO "uncles adopting nephews" $ return reftree_adopt

    let reftree_sort = case sortMethod params of
            NoSort -> reftree_adopt
            NumDP_Distance  -> sortChildren cmp_numdp_distance  reftree_adopt
            NumDP_Distance' -> sortChildren cmp_numdp_distance' reftree_adopt
            Distance_NumDP  -> sortChildren cmp_distance_numdp  reftree_adopt
            Distance_NumDP' -> sortChildren cmp_distance_numdp' reftree_adopt
    timeIO "sorting children" $ return reftree_sort

    let reftree_prune = case packMethod params of
            NoPack -> reftree_sort
            SetLeaves -> setLeaves 0 $ reftree_sort
            PackCT -> packCT $ reftree_sort
--             PackCT2 -> packCT2 20 $ reftree_sort
--             PackCT3 -> packCT3 $ reftree_sort
    {-# SCC reftree_prune #-} timeIO "packing reference tree" $ return reftree_prune


    let reftree_cache = if cache_dists params
            then setMaxDescendentDistance reftree_prune
            else reftree_prune
    time "caching distances" $ reftree_cache


    let reftree_final = reftree_cache
--     let (Just' reftree_final) = reftree

    deepseq reftree_final $ return ()

    -- verbose prints tree stats
    if verbose params
        then do
            putStrLn ""
            printTreeStats "reftree      " $ reftree
            printTreeStats "reftree_prune" $ reftree_final
        else return ()

    -- build query tree
    (querytree,qs) <- case query_file params of
        Nothing -> return $ (reftree_final,rs)
-- | FIXME
--         Just qfile -> do
--             qs <- loaddata $ dataparams { datafile = qfile }
--             let qtree = trainInsert qs :: tree
--             timeIO "building query tree" $ return qtree
--             let qtree_prune = {-packCT $-} unUnit qtree
--             timeIO "packing query tree" $ return qtree_prune
--             return (qtree_prune,qs)

    -- do knn search
    let result = parFindEpsilonNeighborMap
            ( {-fromRational $-} searchEpsilon params )
            ( DualTree
                ( reftree_final )
                ( querytree )
            )
            :: NeighborMap k dp

    res <- timeIO "computing parFindNeighborMap" $ return result

    -- output to files
    let qs_index = Map.fromList $ zip (map WithPreludeOrd $ VG.toList qs) [0::Int ..]
        rs_index = Map.fromList $ zip (map WithPreludeOrd $ VG.toList rs) [0::Int ..]

    timeIO "outputing distance" $ do
        hDistances <- openFile (distances_file params) WriteMode
        sequence_ $
--             map (hPutStrLn hDistances . concat . intersperse "," . map (\x -> showEFloat (Just 10) x ""))
            map (hPutStrLn hDistances . concat . intersperse "," . map show)
            . Map.elems
            . Map.mapKeys (\k -> fromJust $ Map.lookup k qs_index)
            . Map.map (map neighborDistance . getknnL)
            . unsafeGetMap
            $ nm2map res
        hClose hDistances

    timeIO "outputing neighbors" $ do
        hNeighbors <- openFile (neighbors_file params) WriteMode
        sequence_ $
            map (hPutStrLn hNeighbors . init . tail . show)
            . Map.elems
            . Map.map (map (\v -> fromJust $ Map.lookup v rs_index))
            . Map.mapKeys (\k -> fromJust $ Map.lookup k qs_index)
            . Map.map (map (WithPreludeOrd . neighbor) . getknnL)
            . unsafeGetMap
            $ nm2map res
        hClose hNeighbors

    -- end
    putStrLn "end"

-- printTreeStats :: String -> Tree -> IO ()
printTreeStats str t = do
    putStrLn (str++" st stats:")
    putStr (str++"  stNumDp..............") >> hFlush stdout >> putStrLn (show $ stNumDp t)
    putStr (str++"  stNumNodes...........") >> hFlush stdout >> putStrLn (show $ stNumNodes t)
    putStr (str++"  stNumLeaves..........") >> hFlush stdout >> putStrLn (show $ stNumLeaves t)
    putStr (str++"  stNumGhosts..........") >> hFlush stdout >> putStrLn (show $ stNumGhosts t)
    putStr (str++"  stNumGhostSingletons.") >> hFlush stdout >> putStrLn (show $ stNumGhostSingletons t)
    putStr (str++"  stNumGhostLeaves.....") >> hFlush stdout >> putStrLn (show $ stNumGhostLeaves t)
    putStr (str++"  stNumGhostSelfparent.") >> hFlush stdout >> putStrLn (show $ stNumGhostSelfparent t)
    putStr (str++"  stAveGhostChildren...") >> hFlush stdout >> putStrLn (show $ mean $ stAveGhostChildren t)
    putStr (str++"  stMaxLeaves..........") >> hFlush stdout >> putStrLn (show $ stMaxLeaves t)
    putStr (str++"  stAveLeaves..........") >> hFlush stdout >> putStrLn (show $ mean $ stAveLeaves t)
    putStr (str++"  stMaxChildren........") >> hFlush stdout >> putStrLn (show $ stMaxChildren t)
    putStr (str++"  stAveChildren........") >> hFlush stdout >> putStrLn (show $ mean $ stAveChildren t)
    putStr (str++"  stMaxDepth...........") >> hFlush stdout >> putStrLn (show $ stMaxDepth t)
    putStr (str++"  stNumSingletons......") >> hFlush stdout >> putStrLn (show $ stNumSingletons t)
    putStr (str++"  stExtraLeaves........") >> hFlush stdout >> putStrLn (show $ stExtraLeaves t)
    putStrLn (str++" ct stats:")
    putStr (str++"  ctMaxCoverRatio........") >> hFlush stdout >> putStrLn (show $ ctMaxCoverRatio t)
    putStr (str++"  ctAveCoverRatio........") >> hFlush stdout >> putStrLn (show $ mean $ ctAveCoverRatio t)
    putStr (str++"  ctMovableNodes.........") >> hFlush stdout >> putStrLn (show $ ctMovableNodes t)
    putStr (str++"  ctBetterMovableNodes...") >> hFlush stdout >> putStrLn (show $ ctBetterMovableNodes t)
    putStr (str++"  ctMovableParents.......") >> hFlush stdout >> putStrLn (show $ ctMovableParents t)
    putStr (str++"  ctBetterMovableParents.") >> hFlush stdout >> putStrLn (show $ ctBetterMovableParents t)

    putStrLn (str++" invariants:")
    putStr (str++"  covering.....") >> hFlush stdout >> putStrLn (show $ invariant_CoverTree_covering t)
    putStr (str++"  separating...") >> hFlush stdout >> putStrLn (show $ invariant_CoverTree_separating t)
    putStr (str++"  maxDescDist..") >> hFlush stdout >> putStrLn (show $ invariant_maxDescendentDistance t)
    putStr (str++"  leveled......") >> hFlush stdout >> putStrLn (show $ property_leveled t)
--     putStr (str++"  leveled................") >> hFlush stdout >> putStrLn (show $ property_leveled $ Just' t)

    putStrLn ""