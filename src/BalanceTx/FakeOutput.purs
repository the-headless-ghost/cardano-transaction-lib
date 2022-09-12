module BalanceTx.FakeOutput
  ( fakeOutputWithValue
  , fakeOutputWithNonAdaAssets
  ) where

import Prelude

import Cardano.Types.Value (NonAdaAsset, Value, mkValue)
import Data.Maybe (Maybe(Nothing), fromJust)
import Partial.Unsafe (unsafePartial)
import Serialization.Address (addressFromBech32) as Csl
import Types.OutputDatum (OutputDatum(NoOutputDatum))
import Cardano.Types.Transaction (TransactionOutput(TransactionOutput))

fakeOutputWithValue :: Value -> TransactionOutput
fakeOutputWithValue amount =
  TransactionOutput
    { -- this fake address is taken from CSL:
      -- https://github.com/Emurgo/cardano-serialization-lib/blob/a58bfa583297705ffc0fb03923cecef3452a6aee/rust/src/utils.rs#L1146
      address: unsafePartial fromJust $ Csl.addressFromBech32
        "addr_test1qpu5vlrf4xkxv2qpwngf6cjhtw542ayty80v8dyr49rf5ewvxwdrt70qlcpe\
        \eagscasafhffqsxy36t90ldv06wqrk2qum8x5w"
    , amount
    , datum: NoOutputDatum
    , scriptRef: Nothing
    }

fakeOutputWithNonAdaAssets :: NonAdaAsset -> TransactionOutput
fakeOutputWithNonAdaAssets =
  fakeOutputWithValue <<< mkValue mempty
