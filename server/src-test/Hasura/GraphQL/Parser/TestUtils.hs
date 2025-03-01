module Hasura.GraphQL.Parser.TestUtils
  ( TestMonad (..),
    fakeScalar,
    fakeInputFieldValue,
    fakeDirective,
  )
where

import Data.HashMap.Strict qualified as M
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as T
import Hasura.Base.ErrorMessage (fromErrorMessage)
import Hasura.GraphQL.Schema.Parser
import Hasura.Prelude
import Language.GraphQL.Draft.Syntax qualified as G

-- test monad

newtype TestMonad a = TestMonad {runTest :: Either Text a}
  deriving (Functor, Applicative, Monad)

instance MonadParse TestMonad where
  withKey = const id
  parseErrorWith = const $ TestMonad . Left . fromErrorMessage

-- values generation

fakeScalar :: G.Name -> G.Value Variable
fakeScalar =
  G.unName >>> \case
    "Int" -> G.VInt 4242
    "Boolean" -> G.VBoolean False
    name -> error $ "no test value implemented for scalar " <> T.unpack name

fakeInputFieldValue :: InputFieldInfo -> G.Value Variable
fakeInputFieldValue (InputFieldInfo t _) = go t
  where
    go :: forall k. ('Input <: k) => Type k -> G.Value Variable
    go = \case
      TList _ t' -> G.VList [go t', go t']
      TNamed _ (Definition name _ _ _ info) -> case (info, subKind @'Input @k) of
        (TIScalar, _) -> fakeScalar name
        (TIEnum ei, _) -> G.VEnum $ G.EnumValue $ dName $ NE.head ei
        (TIInputObject (InputObjectInfo oi), _) -> G.VObject $
          M.fromList $ do
            Definition fieldName _ _ _ fieldInfo <- oi
            pure (fieldName, fakeInputFieldValue fieldInfo)
        _ -> error "fakeInputFieldValue: non-exhaustive. FIXME"

fakeDirective :: DirectiveInfo -> G.Directive Variable
fakeDirective DirectiveInfo {..} =
  G.Directive diName $
    M.fromList $
      diArguments <&> \(Definition argName _ _ _ argInfo) ->
        (argName, fakeInputFieldValue argInfo)
