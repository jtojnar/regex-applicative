--------------------------------------------------------------------
-- |
-- Module    : Text.Regex.Applicative.Object
-- Copyright : (c) Roman Cheplyaka
-- License   : MIT
--
-- Maintainer: Roman Cheplyaka <roma@ro-che.info>
-- Stability : experimental
--
-- This is a low-level interface to the regex engine.
--------------------------------------------------------------------
{-# LANGUAGE TypeFamilies, GADTs #-}
module Text.Regex.Applicative.Object
    ( ReObject
    , compile
    , emptyObject
    , Thread
    , threads
    , failed
    , isResult
    , getResult
    , results
    , ThreadId
    , threadId
    , step
    , stepThread
    , fromThreads
    , addThread
    ) where

import Text.Regex.Applicative.Types
import qualified Text.Regex.Applicative.StateQueue as SQ
import qualified Text.Regex.Applicative.Compile as Compile
import Data.Maybe
import Control.Monad.Trans.State
import Control.Applicative hiding (empty)

-- | The state of the engine is represented as a \"regex object\" of type
-- @'ReObject' s r@, where @s@ is the type of symbols and @r@ is the
-- result type (as in the 'RE' type). Think of 'ReObject' as a collection of
-- 'Thread's ordered by priority. E.g. threads generated by the left part of
-- '<|>' come before the threads generated by the right part.
newtype ReObject s r = ReObject (SQ.StateQueue (Thread s r))

-- | List of all threads of an object. Each non-result thread has a unique id.
threads :: ReObject s r -> [Thread s r]
threads (ReObject sq) = SQ.getElements sq

-- | Create an object from a list of threads. It is recommended that all
-- threads come from the same 'ReObject', unless you know what you're doing.
-- However, it should be safe to filter out or rearrange threads.
fromThreads :: [Thread s r] -> ReObject s r
fromThreads ts = foldl (flip addThread) emptyObject ts

-- | Check whether a thread is a result thread
isResult :: Thread s r -> Bool
isResult Accept {} = True
isResult _ = False

-- | Return the result of a result thread, or 'Nothing' if it's not a result
-- thread
getResult :: Thread s r -> Maybe r
getResult (Accept r) = Just r
getResult _ = Nothing

-- | Check if the object has no threads. In that case it never will
-- produce any new threads as a result of 'step'.
failed :: ReObject s r -> Bool
failed obj = null $ threads obj

-- | Empty object (with no threads)
emptyObject :: ReObject s r
emptyObject = ReObject $ SQ.empty

-- | Extract the result values from all the result threads of an object
results :: ReObject s r -> [r]
results obj =
    mapMaybe getResult $ threads obj

-- | Feed a symbol into a regex object
step :: s -> ReObject s r -> ReObject s r
step s (ReObject sq) =
    let accum q t =
            case t of
                Accept {} -> q
                Thread _ c ->
                    foldl (\q x -> addThread x q) q $ c s
        newQueue = SQ.fold accum emptyObject sq
    in newQueue

-- | Feed a symbol into a non-result thread. It is an error to call 'stepThread'
-- on a result thread.
stepThread :: s -> Thread s r -> [Thread s r]
stepThread s t =
    case t of
        Thread _ c -> c s
        Accept {} -> error "stepThread on a result"

-- | Add a thread to an object. The new thread will have lower priority than the
-- threads which are already in the object.
--
-- If a (non-result) thread with the same id already exists in the object, the
-- object is not changed.
addThread :: Thread s r -> ReObject s r -> ReObject s r
addThread t (ReObject q) =
    case t of
        Accept {} -> ReObject $ SQ.insert t q
        Thread { threadId_ = ThreadId i } -> ReObject $ SQ.insertUnique i t q

-- | Compile a regular expression into a regular expression object
compile :: RE s r -> ReObject s r
compile =
    fromThreads .
    flip Compile.compile (\x -> [Accept x]) .
    flip evalState (ThreadId 1) .
    getNumbered .
    unRE

instance Regexp f => Regexp (Numbered f) where
    reEps = Numbered $ return reEps
    reSymbol _ p = Numbered $ reSymbol <$> fresh <*> pure p
    reAlt a1 a2 = Numbered $ reAlt <$> getNumbered a1 <*> getNumbered a2
    reApp a1 a2 = Numbered $ reApp <$> getNumbered a1 <*> getNumbered a2
    reFmap f a = Numbered $ reFmap f <$> getNumbered a
    reRep g f b a = Numbered $ reRep g f b <$> getNumbered a
    reVoid a = Numbered $ reVoid <$> getNumbered a

instance Regexp RE where
    reEps = RE reEps
    reSymbol t p = RE $ reSymbol t p
    reAlt a1 a2 = RE $ reAlt (unRE a1) (unRE a2)
    reApp a1 a2 = RE $ reApp (unRE a1) (unRE a2)
    reFmap f a = RE $ reFmap f (unRE a)
    reRep g f b a = RE $ reRep g f b (unRE a)
    reVoid a = RE $ reVoid (unRE a)

fresh :: State ThreadId ThreadId
fresh = do
    t@(ThreadId i) <- get
    put $! ThreadId (i+1)
    return t
