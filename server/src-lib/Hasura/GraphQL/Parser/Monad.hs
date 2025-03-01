-- | Monad transformers for GraphQL schema construction and query parsing.
module Hasura.GraphQL.Parser.Monad
  ( SchemaT,
    runSchemaT,
    Parse,
    runParse,
    ParseError (..),
  )
where

import Control.Arrow ((<<<))
import Control.Monad.Except
import Control.Monad.Reader (MonadReader, ReaderT, mapReaderT)
import Control.Monad.State.Strict (MonadState (..), StateT, evalStateT)
import Data.Aeson (JSONPath)
import Data.Dependent.Map (DMap)
import Data.Dependent.Map qualified as DM
import Data.GADT.Compare.Extended
import Data.IORef
import Data.Kind qualified as K
import Data.Proxy (Proxy (..))
import Hasura.Base.Error
import Hasura.Base.ErrorMessage
import Hasura.GraphQL.Parser.Class
import Language.Haskell.TH qualified as TH
import System.IO.Unsafe (unsafeInterleaveIO)
import Type.Reflection (Typeable, typeRep, (:~:) (..))
import Prelude

-- Disable custom prelude warnings in preparation for extracting this module into a separate package.
{-# ANN module ("HLint: ignore Use onLeft" :: String) #-}

-- -------------------------------------------------------------------------------------------------
-- schema construction

newtype SchemaT n m a = SchemaT
  { unSchemaT :: StateT (DMap ParserId (ParserById n)) m a
  }
  deriving (Functor, Applicative, Monad, MonadError e, MonadReader r)

runSchemaT :: forall m n a. Monad m => SchemaT n m a -> m a
runSchemaT = flip evalStateT mempty . unSchemaT

-- | see Note [SchemaT requires MonadIO]
instance
  (MonadIO m, MonadParse n) =>
  MonadSchema n (SchemaT n m)
  where
  memoizeOn name key buildParser = SchemaT do
    let parserId = ParserId name key
    parsersById <- get
    case DM.lookup parserId parsersById of
      Just (ParserById parser) -> pure parser
      Nothing -> do
        -- We manually do eager blackholing here using a MutVar rather than
        -- relying on MonadFix and ordinary thunk blackholing. Why? A few
        -- reasons:
        --
        --   1. We have more control. We aren’t at the whims of whatever
        --      MonadFix instance happens to get used.
        --
        --   2. We can be more precise. GHC’s lazy blackholing doesn’t always
        --      kick in when you’d expect.
        --
        --   3. We can provide more useful error reporting if things go wrong.
        --      Most usefully, we can include a HasCallStack source location.
        cell <- liftIO $ newIORef Nothing

        -- We use unsafeInterleaveIO here, which sounds scary, but
        -- unsafeInterleaveIO is actually far more safe than unsafePerformIO.
        -- unsafeInterleaveIO just defers the execution of the action until its
        -- result is needed, adding some laziness.
        --
        -- That laziness can be dangerous if the action has side-effects, since
        -- the point at which the effect is performed can be unpredictable. But
        -- this action just reads, never writes, so that isn’t a concern.
        parserById <-
          liftIO $
            unsafeInterleaveIO $
              readIORef cell >>= \case
                Just parser -> pure $ ParserById parser
                Nothing ->
                  error $
                    unlines
                      [ "memoize: parser was forced before being fully constructed",
                        "  parser constructor: " ++ TH.pprint name
                      ]
        put $! DM.insert parserId parserById parsersById

        parser <- unSchemaT buildParser
        liftIO $ writeIORef cell (Just parser)
        pure parser

instance
  (MonadIO m, MonadParse n) =>
  MonadSchema n (ReaderT a (SchemaT n m))
  where
  memoizeOn name key = mapReaderT (memoizeOn name key)

{- Note [SchemaT requires MonadIO]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The MonadSchema instance for SchemaT requires MonadIO, which is unsatisfying.
The only reason the constraint is needed is to implement knot-tying via IORefs
(see Note [Tying the knot] in Hasura.GraphQL.Parser.Class), which really only
requires the power of ST. Using ST would be much nicer, since we could discharge
the burden locally, but unfortunately we also want to use MonadUnique, which
is handled by IO in the end.

This means that we need IO at the base of our monad, so to use STRefs, we’d need
a hypothetical STT transformer (i.e. a monad transformer version of ST). But
such a thing isn’t safe in general, since reentrant monads like ListT or ContT
would incorrectly share state between the different threads of execution.

In theory, this can be resolved by using something like Vault (from the vault
package) to create “splittable” sets of variable references. That would allow
you to create a transformer with an STRef-like interface that works over any
arbitrary monad. However, while the interface would be safe, the implementation
of such an abstraction requires unsafe primitives, and to the best of my
knowledge no such transformer exists in any existing libraries.

So we decide it isn’t worth the trouble and just use MonadIO. If `eff` ever pans
out, it should be able to support this more naturally, so we can fix it then. -}

-- | A key used to distinguish calls to 'memoize'd functions. The 'TH.Name'
-- distinguishes calls to completely different parsers, and the @a@ value
-- records the arguments.
data ParserId (t :: ((K.Type -> K.Type) -> K.Type -> K.Type, K.Type)) where
  ParserId :: (Ord a, Typeable p, Typeable a, Typeable b) => TH.Name -> a -> ParserId '(p, b)

instance GEq ParserId where
  geq
    (ParserId name1 (arg1 :: a1) :: ParserId t1)
    (ParserId name2 (arg2 :: a2) :: ParserId t2)
      | _ :: Proxy '(p1, b1) <- Proxy @t1,
        _ :: Proxy '(p2, b2) <- Proxy @t2,
        name1 == name2,
        Just Refl <- typeRep @a1 `geq` typeRep @a2,
        arg1 == arg2,
        Just Refl <- typeRep @p1 `geq` typeRep @p2,
        Just Refl <- typeRep @b1 `geq` typeRep @b2 =
        Just Refl
      | otherwise = Nothing

instance GCompare ParserId where
  gcompare
    (ParserId name1 (arg1 :: a1) :: ParserId t1)
    (ParserId name2 (arg2 :: a2) :: ParserId t2)
      | _ :: Proxy '(p1, b1) <- Proxy @t1,
        _ :: Proxy '(p2, b2) <- Proxy @t2 =
        strengthenOrdering (compare name1 name2)
          `extendGOrdering` gcompare (typeRep @a1) (typeRep @a2)
          `extendGOrdering` strengthenOrdering (compare arg1 arg2)
          `extendGOrdering` gcompare (typeRep @p1) (typeRep @p2)
          `extendGOrdering` gcompare (typeRep @b1) (typeRep @b2)
          `extendGOrdering` GEQ

-- | A newtype wrapper around a 'Parser' that rearranges the type parameters
-- so that it can be indexed by a 'ParserId' in a 'DMap'.
--
-- This is really just a single newtype, but it’s implemented as a data family
-- because GHC doesn’t allow ordinary datatype declarations to pattern-match on
-- type parameters, and we want to match on the tuple.
data family ParserById (m :: K.Type -> K.Type) (a :: ((K.Type -> K.Type) -> K.Type -> K.Type, K.Type))

newtype instance ParserById m '(p, a) = ParserById (p m a)

-- -------------------------------------------------------------------------------------------------
-- query parsing

newtype Parse a = Parse
  { unParse :: Except ParseError a
  }
  deriving (Functor, Applicative, Monad)

runParse ::
  MonadError QErr m =>
  Parse a ->
  m a
runParse parse =
  either reportParseErrors pure (runExcept <<< unParse $ parse)

instance MonadParse Parse where
  withKey key = Parse . withExceptT (\pe -> pe {pePath = key : pePath pe}) . unParse
  parseErrorWith code message = Parse $ do
    throwError $ ParseError {peCode = code, pePath = [], peMessage = message}

data ParseError = ParseError
  { pePath :: JSONPath,
    peMessage :: ErrorMessage,
    peCode :: Code
  }

reportParseErrors ::
  MonadError QErr m =>
  ParseError ->
  m a
reportParseErrors (ParseError {pePath, peMessage, peCode}) =
  throwError (err400 peCode (fromErrorMessage peMessage)) {qePath = pePath}
