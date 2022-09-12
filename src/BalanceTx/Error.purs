-- | Definitions for error types that may arise during transaction balancing,
-- | along with helpers for parsing and pretty-printing script evaluation errors
-- | that may be returned from Ogmios when calculating ex units.
module BalanceTx.Error
  ( Actual(Actual)
  , BalanceTxError
      ( CouldNotConvertScriptOutputToTxInput
      , CouldNotGetCollateral
      , CouldNotGetUtxos
      , CouldNotGetWalletAddress
      , CollateralReturnError
      , CollateralReturnMinAdaValueCalcError
      , ExUnitsEvaluationFailed
      , InsufficientTxInputs
      , ReindexRedeemersError
      , UtxoLookupFailedFor
      , UtxoMinAdaValueCalculationFailed
      )
  , Expected(Expected)
  , printTxEvaluationFailure
  ) where

import Prelude

import Cardano.Types.Transaction (Redeemer(Redeemer))
import Cardano.Types.Value (Value)
import Data.Array (catMaybes, filter, uncons) as Array
import Data.Bifunctor (bimap)
import Data.BigInt (toString) as BigInt
import Data.Either (Either(Left, Right), either, isLeft)
import Data.Foldable (find, foldl, foldMap, length)
import Data.FoldableWithIndex (foldMapWithIndex)
import Data.Function (applyN)
import Data.Generic.Rep (class Generic)
import Data.Int (toStringAs, decimal, ceil, toNumber)
import Data.Maybe (Maybe(Just, Nothing))
import Data.Newtype (class Newtype)
import Data.Show.Generic (genericShow)
import Data.String (Pattern(Pattern))
import Data.String.CodePoints (length) as String
import Data.String.Common (joinWith, split) as String
import Data.String.Utils (padEnd)
import Data.Tuple (snd)
import Data.Tuple.Nested (type (/\), (/\))
import QueryM.Ogmios
  ( TxEvaluationFailure(UnparsedError, ScriptFailures)
  , RedeemerPointer
  , ScriptFailure
      ( ExtraRedeemers
      , MissingRequiredDatums
      , MissingRequiredScripts
      , ValidatorFailed
      , UnknownInputReferencedByRedeemer
      , NonScriptInputReferencedByRedeemer
      , IllFormedExecutionBudget
      , NoCostModelForLanguage
      )
  ) as Ogmios
import ReindexRedeemers (ReindexErrors)
import Types.Natural (toBigInt) as Natural
import Types.ScriptLookups (UnattachedUnbalancedTx(UnattachedUnbalancedTx))
import Types.Transaction (TransactionInput)

-- | Errors conditions that may possibly arise during transaction balancing
data BalanceTxError
  = CouldNotConvertScriptOutputToTxInput
  | CouldNotGetCollateral
  | CouldNotGetUtxos
  | CouldNotGetWalletAddress
  | CollateralReturnError String
  | CollateralReturnMinAdaValueCalcError
  | ExUnitsEvaluationFailed UnattachedUnbalancedTx Ogmios.TxEvaluationFailure
  | InsufficientTxInputs Expected Actual
  | ReindexRedeemersError ReindexErrors
  | UtxoLookupFailedFor TransactionInput
  | UtxoMinAdaValueCalculationFailed

derive instance Generic BalanceTxError _

instance Show BalanceTxError where
  show (ExUnitsEvaluationFailed tx failure) =
    "ExUnitsEvaluationFailed: " <> printTxEvaluationFailure tx failure
  show e = genericShow e

newtype Actual = Actual Value

derive instance Generic Actual _
derive instance Newtype Actual _

instance Show Actual where
  show = genericShow

newtype Expected = Expected Value

derive instance Generic Expected _
derive instance Newtype Expected _

instance Show Expected where
  show = genericShow

--------------------------------------------------------------------------------
-- Failure parsing for Ogmios.EvaluateTx
--------------------------------------------------------------------------------

type WorkingLine = String
type FrozenLine = String

type PrettyString = Array (Either WorkingLine FrozenLine)

runPrettyString :: PrettyString -> String
runPrettyString ary = String.joinWith "" (either identity identity <$> ary)

freeze :: PrettyString -> PrettyString
freeze ary = either Right Right <$> ary

line :: String -> PrettyString
line s =
  case Array.uncons lines of
    Nothing -> []
    Just { head, tail } -> [ head ] <> freeze tail
  where
  lines = Left <<< (_ <> "\n") <$> String.split (Pattern "\n") s

bullet :: PrettyString -> PrettyString
bullet ary = freeze (bimap ("- " <> _) ("  " <> _) <$> ary)

number :: PrettyString -> PrettyString
number ary = freeze (foldl go [] ary)
  where
  biggestPrefix :: String
  biggestPrefix = toStringAs decimal (length (Array.filter isLeft ary)) <> ". "

  width :: Int
  width = ceil (toNumber (String.length biggestPrefix) / 2.0) * 2

  numberLine :: Int -> String -> String
  numberLine i l = padEnd width (toStringAs decimal (i + 1) <> ". ") <> l

  indentLine :: String -> String
  indentLine = applyN ("  " <> _) (width / 2)

  go :: PrettyString -> Either WorkingLine FrozenLine -> PrettyString
  go b a = b <> [ bimap (numberLine $ length b) indentLine a ]

-- | Pretty print the failure response from Ogmios's EvaluateTx endpoint.
-- | Exported to allow testing, use `Test.Ogmios.Aeson.printEvaluateTxFailures`
-- | to visually verify the printing of errors without a context on fixtures.
printTxEvaluationFailure
  :: UnattachedUnbalancedTx -> Ogmios.TxEvaluationFailure -> String
printTxEvaluationFailure (UnattachedUnbalancedTx { redeemersTxIns }) e =
  runPrettyString $ case e of
    Ogmios.UnparsedError error -> line $ "Unknown error: " <> error
    Ogmios.ScriptFailures sf -> line "Script failures:" <> bullet
      (foldMapWithIndex printScriptFailures sf)
  where
  lookupRedeemerPointer
    :: Ogmios.RedeemerPointer -> Maybe (Redeemer /\ Maybe TransactionInput)
  lookupRedeemerPointer ptr = flip find redeemersTxIns
    $ \(Redeemer rdmr /\ _) -> rdmr.tag == ptr.redeemerTag && rdmr.index ==
        Natural.toBigInt ptr.redeemerIndex

  printRedeemerPointer :: Ogmios.RedeemerPointer -> PrettyString
  printRedeemerPointer ptr =
    line
      ( show ptr.redeemerTag <> ":" <> BigInt.toString
          (Natural.toBigInt ptr.redeemerIndex)
      )

  -- TODO Investigate if more details can be printed, for example minting
  -- policy/minted assets
  -- https://github.com/Plutonomicon/cardano-transaction-lib/issues/881
  printRedeemerDetails :: Ogmios.RedeemerPointer -> PrettyString
  printRedeemerDetails ptr =
    let
      mbRedeemerTxIn = lookupRedeemerPointer ptr
      mbData = mbRedeemerTxIn <#> \(Redeemer r /\ _) -> "Redeemer: " <> show
        r.data
      mbTxIn = (mbRedeemerTxIn >>= snd) <#> \txIn -> "Input: " <> show txIn
    in
      foldMap line $ Array.catMaybes [ mbData, mbTxIn ]

  printRedeemer :: Ogmios.RedeemerPointer -> PrettyString
  printRedeemer ptr =
    printRedeemerPointer ptr <> bullet (printRedeemerDetails ptr)

  printScriptFailure :: Ogmios.ScriptFailure -> PrettyString
  printScriptFailure = case _ of
    Ogmios.ExtraRedeemers ptrs -> line "Extra redeemers:" <> bullet
      (foldMap printRedeemer ptrs)
    Ogmios.MissingRequiredDatums { provided, missing }
    -> line "Supplied with datums:"
      <> bullet (foldMap (foldMap line) provided)
      <> line "But missing required datums:"
      <> bullet (foldMap line missing)
    Ogmios.MissingRequiredScripts { resolved, missing }
    -> line "Supplied with scripts:"
      <> bullet
        ( foldMapWithIndex
            (\ptr scr -> printRedeemer ptr <> line ("Script: " <> scr))
            resolved
        )
      <> line "But missing required scripts:"
      <> bullet (foldMap line missing)
    Ogmios.ValidatorFailed { error, traces } -> line error <> line "Trace:" <>
      number
        (foldMap line traces)
    Ogmios.UnknownInputReferencedByRedeemer txIn -> line
      ("Unknown input referenced by redeemer: " <> show txIn)
    Ogmios.NonScriptInputReferencedByRedeemer txIn -> line
      ("Non script input referenced by redeemer: " <> show txIn)
    Ogmios.IllFormedExecutionBudget Nothing -> line
      ("Ill formed execution budget: Execution budget missing")
    Ogmios.IllFormedExecutionBudget (Just { memory, steps }) ->
      line "Ill formed execution budget:"
        <> bullet
          ( line ("Memory: " <> BigInt.toString (Natural.toBigInt memory))
              <> line ("Steps: " <> BigInt.toString (Natural.toBigInt steps))
          )
    Ogmios.NoCostModelForLanguage language -> line
      ("No cost model for language \"" <> language <> "\"")

  printScriptFailures
    :: Ogmios.RedeemerPointer -> Array Ogmios.ScriptFailure -> PrettyString
  printScriptFailures ptr sfs = printRedeemer ptr <> bullet
    (foldMap printScriptFailure sfs)
