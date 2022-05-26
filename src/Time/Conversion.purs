module Time.Conversion
  ( AbsTime(..)
  , ModTime(..)
  , PosixTimeToSlotError(..)
  , RelTime(..)
  , SlotToPosixTimeError(..)
  , posixTimeToSlot
  , slotToPosixTime
  ) where

import Prelude
import Control.Monad.Error.Class (throwError)
import Control.Monad.Except.Trans (runExceptT)
import Data.Array (find)
import Data.BigInt (BigInt)
import Data.BigInt (fromInt, fromNumber) as BigInt
import Data.Either (Either, note)
import Data.Generic.Rep (class Generic)
import Data.JSDate (getTime, parse)
import Data.Maybe (Maybe, maybe)
import Data.Newtype (class Newtype, unwrap, wrap)
import Data.Show.Generic (genericShow)
import Data.Tuple.Nested (type (/\), (/\))
import Effect.Class (liftEffect)
import Helpers (bigIntToUInt, liftEither, liftM, uIntToBigInt)
import QueryM (QueryM)
import QueryM.Ogmios
  ( AbsSlot(AbsSlot)
  , EraSummariesQR(EraSummariesQR)
  , EraSummary(EraSummary)
  , SystemStartQR
  )
import Serialization.Address (Slot)
import Time.Types.POSIXTime (POSIXTime(POSIXTime))

--------------------------------------------------------------------------------
-- Slot (absolute from System Start - see QueryM.SystemStart.getSystemStart)
-- to POSIXTime (milliseconds)
--------------------------------------------------------------------------------
data SlotToPosixTimeError
  = ParseToDataTime SystemStartQR
  | CannotFindSlotInEraSummaries AbsSlot
  | StartingSlotGreaterThanSlot AbsSlot
  | EndTimeLessThanTime AbsTime
  | CannotGetBigIntFromNumber

derive instance Generic SlotToPosixTimeError _
derive instance Eq SlotToPosixTimeError

instance Show SlotToPosixTimeError where
  show = genericShow

-- Based on:
-- https://github.com/input-output-hk/cardano-ledger/blob/2acff66e84d63a81de904e1c0de70208ff1819ea/eras/alonzo/impl/src/Cardano/Ledger/Alonzo/TxInfo.hs#L186
-- https://github.com/input-output-hk/cardano-ledger/blob/1ec8b1428163dc36105b84735725414e1f4829be/eras/shelley/impl/src/Cardano/Ledger/Shelley/HardForks.hs
-- https://github.com/input-output-hk/cardano-base/blob/8fe904d629194b1fbaaf2d0a4e0ccd17052e9103/slotting/src/Cardano/Slotting/EpochInfo/API.hs#L80
-- https://input-output-hk.github.io/ouroboros-network/ouroboros-consensus/src/Ouroboros.Consensus.HardFork.History.EpochInfo.html
-- https://github.com/input-output-hk/ouroboros-network/blob/bd9e5653647c3489567e02789b0ec5b75c726db2/ouroboros-consensus/src/Ouroboros/Consensus/HardFork/History/Qry.hs#L461-L481
-- | Converts a CSL (Absolute) `Slot` (Unsigned Integer) to `POSIXTime` which
-- | is time elapsed from January 1, 1970 (midnight UTC/GMT). We obtain this
-- | By converting `Slot` to `AbsTime` which is time relative to some System
-- | Start, then add any excess for a UNIX Epoch time. Recall that POSIXTime
-- | is in milliseconds for Protocol Version >= 6.
slotToPosixTime
  :: EraSummariesQR
  -> SystemStartQR
  -> Slot
  -> QueryM (Either SlotToPosixTimeError POSIXTime)
slotToPosixTime eraSummaries sysStart slot = runExceptT do
  let absSlot = absSlotFromSlot slot
  -- Get JSDate:
  sysStartD <- liftEffect $ parse $ unwrap sysStart
  -- Find current era:
  currentEra <- liftEither $ findSlotEraSummary eraSummaries absSlot
  -- Convert absolute slot (relative to System start) to relative slot of era
  relSlot <- liftEither $ relSlotFromAbsSlot currentEra absSlot
  -- Convert relative slot to relative time for that era
  let relTime = relTimeFromRelSlot currentEra relSlot
  absTime <- liftEither $ absTimeFromRelTime currentEra relTime
  -- Get POSIX time for system start
  sysStartPosix <- liftM CannotGetBigIntFromNumber
    $ BigInt.fromNumber
    $ getTime sysStartD
  -- Add the system start time to the absolute time relative to system start
  -- to get overall POSIXTime, then convert to milliseconds
  pure $ wrap $ transTime $ sysStartPosix + unwrap absTime
  where
  -- TODO: See https://github.com/input-output-hk/cardano-ledger/blob/master/eras/shelley/impl/src/Cardano/Ledger/Shelley/HardForks.hs#L57
  -- translateTimeForPlutusScripts and ensure protocol version > 5 which would
  -- mean converting to milliseconds
  transTime :: BigInt -> BigInt
  transTime = (*) $ BigInt.fromInt 1000 -- to milliseconds

-- | Convert a CSL (Absolute) `Slot` (`UInt`) to an Ogmios absolute slot
-- | (`BigInt`)
absSlotFromSlot :: Slot -> AbsSlot
absSlotFromSlot = wrap <<< uIntToBigInt <<< unwrap

-- | Convert an Ogmios absolute slot (`BigInt`) to a CSL (Absolute) `Slot`
-- | (`UInt`)
slotFromAbsSlot :: AbsSlot -> Maybe Slot
slotFromAbsSlot = map wrap <<< bigIntToUInt <<< unwrap

-- | Finds the `EraSummary` an `AbsSlot` lies inside (if any).
findSlotEraSummary
  :: EraSummariesQR
  -> AbsSlot -- Slot we are testing and trying to find inside `EraSummariesQR`
  -> Either SlotToPosixTimeError EraSummary
findSlotEraSummary (EraSummariesQR eraSummaries) os =
  note (CannotFindSlotInEraSummaries os) $ find pred eraSummaries
  where
  -- Potential FIXME: In the case of `Just`, do we want to use `safeZone` from
  -- `parameters` to provide a buffer?
  pred :: EraSummary -> Boolean
  pred (EraSummary { start, end }) =
    (unwrap start).slot <= os && maybe true ((<) os <<< _.slot <<< unwrap) end

-- getEstAbsSlot :: EraSummaryTime -> AbsSlot
-- getEstAbsSlot (EraSummaryTime es) = es.slot

-- | Relative slot of an `AbsSlot` within an `EraSummary`
newtype RelSlot = RelSlot BigInt

derive instance Generic RelSlot _
derive instance Newtype RelSlot _
derive newtype instance Eq RelSlot
derive newtype instance Ord RelSlot

instance Show RelSlot where
  show = genericShow

-- | Relative time to the start of an `EraSummary
newtype RelTime = RelTime BigInt

derive instance Generic RelTime _
derive instance Newtype RelTime _
derive newtype instance Eq RelTime
derive newtype instance Ord RelTime

instance Show RelTime where
  show = genericShow

-- | Any leftover time from using `mod` when dividing my slot length.
newtype ModTime = ModTime BigInt

derive instance Generic ModTime _
derive instance Newtype ModTime _
derive newtype instance Eq ModTime
derive newtype instance Ord ModTime

instance Show ModTime where
  show = genericShow

-- | Absolute time relative to System Start, not UNIX epoch.
newtype AbsTime = AbsTime BigInt

derive instance Generic AbsTime _
derive instance Newtype AbsTime _
derive newtype instance Eq AbsTime
derive newtype instance Ord AbsTime

instance Show AbsTime where
  show = genericShow

-- | Find the relative slot provided we know the `AbsSlot` for an absolute slot
-- | given an `EraSummary`. We could relax the `Either` monad if we use this
-- | in conjunction with `findSlotEraSummary`. However, we choose to make the
-- | function more general, guarding against a larger `start`ing slot
relSlotFromAbsSlot
  :: EraSummary -> AbsSlot -> Either SlotToPosixTimeError RelSlot
relSlotFromAbsSlot (EraSummary { start }) as@(AbsSlot absSlot) = do
  let startSlot = unwrap (unwrap start).slot
  unless (startSlot <= absSlot) (throwError $ StartingSlotGreaterThanSlot as)
  pure $ wrap $ absSlot - startSlot

relTimeFromRelSlot :: EraSummary -> RelSlot -> RelTime
relTimeFromRelSlot (EraSummary { parameters }) (RelSlot relSlot) =
  let
    slotLength = unwrap (unwrap parameters).slotLength
  in
    wrap $ relSlot * slotLength

-- As justified in https://github.com/input-output-hk/ouroboros-network/blob/bd9e5653647c3489567e02789b0ec5b75c726db2/ouroboros-consensus/src/Ouroboros/Consensus/HardFork/History/Qry.hs#L461-L481
-- Treat the upperbound as inclusive.
-- | Returns the absolute time relative to some system start, not UNIX epoch.
absTimeFromRelTime
  :: EraSummary -> RelTime -> Either SlotToPosixTimeError AbsTime
absTimeFromRelTime (EraSummary { start, end }) (RelTime relTime) = do
  let
    startTime = unwrap (unwrap start).time
    absTime = startTime + relTime -- relative to System Start, not UNIX Epoch.
    -- If `EraSummary` doesn't have an end, the condition is automatically
    -- satisfied. We use `<=` as justified by the source code.
    endTime = maybe (absTime + one) (unwrap <<< _.slot <<< unwrap) end
  unless (absTime <= endTime) (throwError $ EndTimeLessThanTime $ wrap absTime)
  pure $ wrap absTime

--------------------------------------------------------------------------------
-- POSIXTime (milliseconds) to
-- Slot (absolute from System Start - see QueryM.SystemStart.getSystemStart)
--------------------------------------------------------------------------------
data PosixTimeToSlotError
  = CannotFindTimeInEraSummaries AbsTime
  | PosixTimeBeforeSystemStart POSIXTime
  | StartTimeGreaterThanTime AbsTime
  | EndSlotLessThanSlot AbsSlot
  | RelModNonZero ModTime
  | CannotConvertAbsSlotToSlot AbsSlot
  | CannotGetBigIntFromNumber' -- refactor?

derive instance Generic PosixTimeToSlotError _
derive instance Eq PosixTimeToSlotError

instance Show PosixTimeToSlotError where
  show = genericShow

posixTimeToSlot
  :: EraSummariesQR
  -> SystemStartQR
  -> POSIXTime
  -> QueryM (Either PosixTimeToSlotError Slot)
posixTimeToSlot eraSummaries sysStart pt@(POSIXTime pt') = runExceptT do
  -- Convert to seconds, precision issues?
  let posixTime = transTime pt'
  -- Get JSDate:
  sysStartD <- liftEffect $ parse $ unwrap sysStart
  -- Get POSIX time for system start
  sysStartPosix <- liftM CannotGetBigIntFromNumber'
    $ BigInt.fromNumber
    $ getTime sysStartD
  -- Ensure the time we are converting is after the system start, otherwise
  -- we have negative slots.
  unless (sysStartPosix <= posixTime)
    $ throwError
    $ PosixTimeBeforeSystemStart pt
  let absTime = wrap $ posixTime - sysStartPosix
  -- Find current era:
  currentEra <- liftEither $ findTimeEraSummary eraSummaries absTime
  -- Get relative time from absolute time w.r.t. current era
  relTime <- liftEither $ relTimeFromAbsTime currentEra absTime
  -- Convert to relative slot
  let relSlotMod = relSlotFromRelTime currentEra relTime
  -- Get absolute slot relative to system start
  absSlot <- liftEither $ absSlotFromRelSlot currentEra relSlotMod
  -- Convert back to UInt `Slot`
  liftM (CannotConvertAbsSlotToSlot absSlot) $ slotFromAbsSlot absSlot
  where
  -- TODO: See https://github.com/input-output-hk/cardano-ledger/blob/master/eras/shelley/impl/src/Cardano/Ledger/Shelley/HardForks.hs#L57
  -- translateTimeForPlutusScripts and ensure protocol version > 5 which would
  -- mean converting to milliseconds
  -- POTENTIAL FIXME: ADD TRUNCATE?
  transTime :: BigInt -> BigInt
  transTime = flip (/) $ BigInt.fromInt 1000 -- to milliseconds

-- | Finds the `EraSummary` an `AbsTime` lies inside (if any).
findTimeEraSummary
  :: EraSummariesQR
  -> AbsTime -- Time we are testing and trying to find inside `EraSummariesQR`
  -> Either PosixTimeToSlotError EraSummary
findTimeEraSummary (EraSummariesQR eraSummaries) absTime@(AbsTime at) =
  note (CannotFindTimeInEraSummaries absTime) $ find pred eraSummaries
  where
  pred :: EraSummary -> Boolean
  pred (EraSummary { start, end }) =
    unwrap (unwrap start).time <= at
      && maybe true ((<) at <<< unwrap <<< _.time <<< unwrap) end

relTimeFromAbsTime
  :: EraSummary -> AbsTime -> Either PosixTimeToSlotError RelTime
relTimeFromAbsTime (EraSummary { start }) at@(AbsTime absTime) = do
  let startTime = unwrap (unwrap start).time
  unless (startTime <= absTime) (throwError $ StartTimeGreaterThanTime at)
  let relTime = absTime - startTime -- relative to era start, not UNIX Epoch.
  pure $ wrap relTime

-- | Converts relative time to relative slot (using Euclidean division) and
-- | modulus for any leftover.
relSlotFromRelTime
  :: EraSummary -> RelTime -> RelSlot /\ ModTime
relSlotFromRelTime (EraSummary { parameters }) (RelTime relTime) =
  let
    slotLength = unwrap (unwrap parameters).slotLength
  in
    wrap (relTime `div` slotLength) /\ wrap (relTime `mod` slotLength) -- Euclidean division okay as everything is non-negative

absSlotFromRelSlot
  :: EraSummary -> RelSlot /\ ModTime -> Either PosixTimeToSlotError AbsSlot
absSlotFromRelSlot
  (EraSummary { start, end })
  (RelSlot relSlot /\ mt@(ModTime modTime)) = do
  let
    startSlot = unwrap (unwrap start).slot
    absSlot = startSlot + relSlot -- relative to system start
    -- If `EraSummary` doesn't have an end, the condition is automatically
    -- satisfied. We use `<=` as justified by the source code.
    endSlot = maybe (absSlot + one) (unwrap <<< _.slot <<< unwrap) end
  unless (absSlot <= endSlot) (throwError $ EndSlotLessThanSlot $ wrap absSlot)
  -- Check for no remainder:
  unless (modTime == zero) (throwError $ RelModNonZero mt)
  -- Potential FIXME: Do we want to use `safeZone` from `parameters`.
  pure $ wrap absSlot

--------------------------------------------------------------------------------

-- -- | Convert a `SlotRange` to a `POSIXTimeRange` given a `SlotConfig`. The
-- -- | resulting `POSIXTimeRange` refers to the starting time of the lower bound of
-- -- | the `SlotRange` and the ending time of the upper bound of the `SlotRange`.
-- slotRangeToPOSIXTimeRange :: SlotConfig -> SlotRange -> POSIXTimeRange
-- slotRangeToPOSIXTimeRange
--   sc
--   (Interval { from: LowerBound start startIncl, to: UpperBound end endIncl }) =
--   let
--     lbound =
--       map
--         (if startIncl then slotToBeginPOSIXTime sc else slotToEndPOSIXTime sc)
--         start
--     ubound =
--       map
--         (if endIncl then slotToEndPOSIXTime sc else slotToBeginPOSIXTime sc)
--         end
--   in
--     Interval
--       { from: LowerBound lbound startIncl
--       , to: UpperBound ubound endIncl
--       }

-- -- | Convert a `Slot` to a `POSIXTimeRange` given a `SlotConfig`. Each `Slot`
-- -- | can be represented by an interval of time.
-- slotToPOSIXTimeRange :: SlotConfig -> Slot -> POSIXTimeRange
-- slotToPOSIXTimeRange sc slot =
--   interval (slotToBeginPOSIXTime sc slot) (slotToEndPOSIXTime sc slot)

-- -- | Get the starting `POSIXTime` of a `Slot` given a `SlotConfig`.
-- slotToBeginPOSIXTime :: SlotConfig -> Slot -> POSIXTime
-- slotToBeginPOSIXTime (SlotConfig { slotLength, slotZeroTime }) (Slot n) =
--   let
--     msAfterBegin = uIntToBigInt n * slotLength
--   in
--     POSIXTime $ unwrap slotZeroTime + msAfterBegin

-- -- | Get the ending `POSIXTime` of a `Slot` given a `SlotConfig`.
-- slotToEndPOSIXTime :: SlotConfig -> Slot -> POSIXTime
-- slotToEndPOSIXTime sc@(SlotConfig { slotLength }) slot =
--   slotToBeginPOSIXTime sc slot + POSIXTime (slotLength - one)

-- -- | Convert a `POSIXTimeRange` to `SlotRange` given a `SlotConfig`. This gives
-- -- | the biggest slot range that is entirely contained by the given time range.
-- posixTimeRangeToContainedSlotRange
--   :: SlotConfig -> POSIXTimeRange -> Maybe SlotRange
-- posixTimeRangeToContainedSlotRange sc ptr = do
--   let
--     Interval
--       { from: LowerBound start startIncl
--       , to: UpperBound end endIncl
--       } = map (posixTimeToEnclosingSlot sc) ptr

--     -- Determines the closure of the interval with a handler over whether it's
--     -- the start or end of the interval and a default Boolean if we aren't
--     -- dealing with the `Finite` case.
--     closureWith
--       :: (SlotConfig -> Slot -> POSIXTime)
--       -> Boolean -- Default Boolean
--       -> Extended Slot
--       -> Boolean
--     closureWith f def = case _ of
--       Finite s -> f sc s `member` ptr
--       _ -> def

--     seqExtended :: Extended (Maybe Slot) -> Maybe (Extended Slot)
--     seqExtended = case _ of
--       Finite (Just s) -> pure $ Finite s
--       Finite Nothing -> Nothing
--       NegInf -> pure NegInf
--       PosInf -> pure PosInf

--   -- Fail if any of the outputs of `posixTimeToEnclosingSlot` are `Nothing`.
--   start' <- seqExtended start
--   end' <- seqExtended end
--   pure $ Interval
--     { from: LowerBound start'
--         (closureWith slotToBeginPOSIXTime startIncl start')
--     , to: UpperBound end' (closureWith slotToBeginPOSIXTime endIncl end')
--     }

-- type TransactionValiditySlot =
--   { validityStartInterval :: Maybe Slot, timeToLive :: Maybe Slot }

-- -- | Converts a SlotRange to two separate slots used in building Types.Transaction.
-- -- | Note that we lose information regarding whether the bounds are included
-- -- | or not at `NegInf` and `PosInf`.
-- -- | `Nothing` for `validityStartInterval` represents `Slot zero`.
-- -- | `Nothing` for `timeToLive` represents `maxSlot`.
-- -- | For `Finite` values exclusive of bounds, we add and subtract one slot for
-- -- | `validityStartInterval` and `timeToLive`, respectively.
-- slotRangeToTransactionSlot
--   :: SlotRange
--   -> TransactionValiditySlot
-- slotRangeToTransactionSlot
--   (Interval { from: LowerBound start startIncl, to: UpperBound end endIncl }) =
--   { validityStartInterval, timeToLive }
--   where
--   validityStartInterval :: Maybe Slot
--   validityStartInterval = case start, startIncl of
--     Finite s, true -> pure s
--     Finite s, false -> pure $ s <> Slot one
--     NegInf, _ -> Nothing
--     PosInf, _ -> pure maxSlot

--   timeToLive :: Maybe Slot
--   timeToLive = case end, endIncl of
--     Finite s, true -> pure s
--     Finite s, false -> pure $ s <> Slot (negate one)
--     NegInf, _ -> pure $ Slot zero
--     PosInf, _ -> Nothing

-- -- | Maximum slot under `Data.UInt`
-- maxSlot :: Slot
-- maxSlot = Slot $ unsafePartial fromJust $ UInt.fromString "4294967295"

-- posixTimeRangeToTransactionSlot
--   :: SlotConfig -> POSIXTimeRange -> Maybe TransactionValiditySlot
-- posixTimeRangeToTransactionSlot sc =
--   map slotRangeToTransactionSlot <<< posixTimeRangeToContainedSlotRange sc

-- -- | Convert a `POSIXTime` to `Slot` given a `SlotConfig`. This differs from
-- -- | Plutus by potential failure.
-- posixTimeToEnclosingSlot :: SlotConfig -> POSIXTime -> Maybe Slot
-- posixTimeToEnclosingSlot (SlotConfig { slotLength, slotZeroTime }) (POSIXTime t) =
--   let
--     timePassed = t - unwrap slotZeroTime
--     -- Plutus uses inbuilt `divide` which rounds towards downwards which is `quot`
--     -- not `div`.
--     slotsPassed = quot timePassed slotLength
--   in
--     Slot <$> bigIntToUInt slotsPassed

-- -- TO DO: https://github.com/Plutonomicon/cardano-transaction-lib/issues/169
-- -- -- | Get the current slot number
-- -- currentSlot :: SlotConfig -> Effect Slot
