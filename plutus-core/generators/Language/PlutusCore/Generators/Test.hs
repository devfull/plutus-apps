-- | This module defines functions useful for testing.

{-# LANGUAGE TypeFamilies  #-}
{-# LANGUAGE TypeOperators #-}

module Language.PlutusCore.Generators.Test
    ( TypeEvalCheckError (..)
    , TypeEvalCheckResult (..)
    , TypeEvalCheckM
    , typeEvalCheckBy
    , unsafeTypeEvalCheck
    , getSampleTermValue
    , getSampleProgramAndValue
    , printSampleProgramAndValue
    , sampleProgramValueGolden
    , propEvaluate
    ) where

import           PlutusPrelude                                         (ShowPretty (..))

import           Language.PlutusCore.Constant
import           Language.PlutusCore.Core
import           Language.PlutusCore.Evaluation.Machine.Exception
import           Language.PlutusCore.Evaluation.Machine.ExMemory
import           Language.PlutusCore.Evaluation.Result
import           Language.PlutusCore.Generators.Interesting
import           Language.PlutusCore.Generators.Internal.TypeEvalCheck
import           Language.PlutusCore.Generators.Internal.Utils
import           Language.PlutusCore.Name
import           Language.PlutusCore.Pretty
import           Language.PlutusCore.Universe

import           Control.Monad.Except
import           Data.Functor                                          ((<&>))
import qualified Data.Text.IO                                          as Text
import           Hedgehog                                              hiding (Size, Var, eval)
import qualified Hedgehog.Gen                                          as Gen
import           System.FilePath                                       ((</>))

-- | Generate a term using a given generator and check that it's well-typed and evaluates correctly.
getSampleTermValue
    :: (uni ~ DefaultUni, KnownType (Term TyName Name uni ()) a)
    => TermGen uni a
    -> IO (TermOf (Term TyName Name uni ()) (EvaluationResult (Term TyName Name uni ())))
getSampleTermValue genTerm = Gen.sample $ unsafeTypeEvalCheck <$> genTerm

-- | Generate a program using a given generator and check that it's well-typed and evaluates correctly.
getSampleProgramAndValue
    :: (uni ~ DefaultUni, KnownType (Term TyName Name uni ()) a)
    => TermGen uni a -> IO (Program TyName Name uni (), EvaluationResult (Term TyName Name uni ()))
getSampleProgramAndValue genTerm =
    getSampleTermValue genTerm <&> \(TermOf term result) ->
        (Program () (defaultVersion ()) term, result)

-- | Generate a program using a given generator, check that it's well-typed and evaluates correctly
-- and pretty-print it to stdout using the default pretty-printing mode.
printSampleProgramAndValue
    :: KnownType (Term TyName Name DefaultUni ()) a => TermGen DefaultUni a -> IO ()
printSampleProgramAndValue =
    getSampleProgramAndValue >=> \(program, value) -> do
        putStrLn $ displayPlcDef program
        putStrLn ""
        putStrLn $ displayPlcDef value

-- | Generate a pair of files: @<folder>.<name>.plc@ and @<folder>.<name>.plc.golden@.
-- The first file contains a term generated by a term generator (wrapped in 'Program'),
-- the second file contains the result of evaluation of the term.
sampleProgramValueGolden
    :: KnownType (Term TyName Name DefaultUni ()) a
    => String                -- ^ @folder@
    -> String                -- ^ @name@
    -> TermGen DefaultUni a  -- ^ A term generator.
    -> IO ()
sampleProgramValueGolden folder name genTerm = do
    let filePlc       = folder </> (name ++ ".plc")
        filePlcGolden = folder </> (name ++ ".plc.golden")
    (program, value) <- getSampleProgramAndValue genTerm
    Text.writeFile filePlc       $ displayPlcDef program
    Text.writeFile filePlcGolden $ displayPlcDef value

-- | A property-based testing procedure for evaluators.
-- Checks whether a term generated along with the value it's supposed to compute to
-- indeed computes to that value according to the provided evaluate.
propEvaluate
    :: ( uni ~ DefaultUni, KnownType (Term TyName Name uni ()) a
       , Pretty internal, PrettyPlc termErr
       )
    => (Plain Term uni -> Either (EvaluationException internal user termErr) (Plain Term uni))
                      -- ^ An evaluator.
    -> TermGen uni a  -- ^ A term/value generator.
    -> Property
propEvaluate eval genTermOfTbv = withTests 200 . property $ do
    termOfTbv <- forAllNoShow genTermOfTbv
    case typeEvalCheckBy eval termOfTbv of
        Left (TypeEvalCheckErrorIllFormed err)             -> fail $ prettyPlcErrorString err
        Left (TypeEvalCheckErrorIllTyped expected actual)  ->
            -- We know that these two are distinct, but there is no nice way we
            -- can report this via 'hedgehog' except by comparing them here again.
            ShowPretty expected === ShowPretty actual
        Left (TypeEvalCheckErrorException err)             -> fail err
        Left (TypeEvalCheckErrorIllEvaled expected actual) ->
            -- Ditto.
            ShowPretty expected === ShowPretty actual
        Right _                                            -> return ()