{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE StandaloneDeriving #-}
module Data.Winery
  ( Schema(..)
  , Tag(..)
  , Serialise(..)
  , DecodeException(..)
  , schema
  -- * Standalone serialisation
  , toBuilderWithSchema
  , serialise
  , deserialise
  , deserialiseBy
  , deserialiseTerm
  , splitSchema
  , writeFileSerialise
  -- * Separate serialisation
  , Extractor(..)
  , Decoder
  , serialiseOnly
  , getDecoder
  , getDecoderBy
  -- * Decoding combinators
  , Term(..)
  , Plan(..)
  , extractListBy
  , extractField
  , extractFieldBy
  , extractConstructor
  , extractConstructorBy
  -- * Variable-length quantity
  , VarInt(..)
  -- * Internal
  , unwrapExtractor
  , Strategy
  , Strategy'
  , StrategyError
  , unexpectedSchema
  , unexpectedSchema'
  -- * Generics
  , WineryRecord(..)
  , GSerialiseRecord
  , gschemaViaRecord
  , GEncodeRecord
  , gtoBuilderRecord
  , gextractorRecord
  , gdecodeCurrentRecord
  , GSerialiseVariant
  , gschemaViaVariant
  , gtoBuilderVariant
  , gextractorVariant
  , gdecodeCurrentVariant
  -- * Preset schema
  , bootstrapSchema
  )where

import Control.Applicative
import Control.Exception
import Control.Monad.Trans.State.Strict
import Control.Monad.Reader
import qualified Data.ByteString as B
import qualified Data.ByteString.FastBuilder as BB
import qualified Data.ByteString.Lazy as BL
import qualified Data.Aeson as J
import Data.Bits
import Data.Dynamic
import Data.Functor.Compose
import Data.Functor.Identity
import Data.Foldable
import Data.Proxy
import Data.Scientific (Scientific, scientific, coefficient, base10Exponent)
import Data.Hashable (Hashable)
import qualified Data.HashMap.Strict as HM
import Data.Int
import qualified Data.IntMap as IM
import qualified Data.IntSet as IS
import Data.List (elemIndex)
import qualified Data.Map as M
import Data.Word
import Data.Winery.Internal
import qualified Data.Sequence as Seq
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Vector as V
import qualified Data.Vector.Storable as SV
import qualified Data.Vector.Unboxed as UV
import Data.Text.Prettyprint.Doc hiding ((<>), SText, SChar)
import Data.Text.Prettyprint.Doc.Render.Terminal
import Data.Time.Clock
import Data.Time.Clock.POSIX
import Data.Typeable
import GHC.Exts (IsList(..), IsString(..))
import GHC.Generics
import System.IO
import Unsafe.Coerce

data Schema = SFix Schema -- ^ binds a fixpoint
  | SSelf !Word8 -- ^ @SSelf n@ refers to the n-th innermost fixpoint
  | SVector !Schema
  | SProduct (V.Vector Schema)
  | SRecord [(T.Text, Schema)]
  | SVariant [(T.Text, Schema)]
  | SSchema !Word8
  | SBool
  | SChar
  | SWord8
  | SWord16
  | SWord32
  | SWord64
  | SInt8
  | SInt16
  | SInt32
  | SInt64
  | SInteger
  | SFloat
  | SDouble
  | SBytes
  | SText
  | SUTCTime
  | STag !Tag !Schema
  deriving (Show, Read, Eq, Generic)

-- | Tag is an extra value that can be attached to a schema.
data Tag = TagInt !Int
  | TagStr !T.Text
  | TagList ![Tag]
  deriving (Show, Read, Eq, Generic)

-- | Method definitions are rather arbitrary
instance Num Tag where
  s + t = ["+", s, t]
  s - t = ["-", s, t]
  s * t = ["*", s, t]
  negate s = ["negate", s]
  abs s = ["abs", s]
  signum s = ["signum", s]
  fromInteger = TagInt . fromInteger

instance IsString Tag where
  fromString = TagStr . fromString

instance IsList Tag where
  type Item Tag = Tag
  fromList = TagList
  toList (TagList xs) = xs
  toList _ = []

instance Serialise Tag

instance Pretty Tag where
  pretty (TagInt i) = pretty i
  pretty (TagStr s) = pretty s
  pretty (TagList xs) = list (map pretty xs)

instance Pretty Schema where
  pretty = \case
    SSchema v -> "Schema " <> pretty v
    SProduct [] -> "()"
    SBool -> "Bool"
    SChar -> "Char"
    SWord8 -> "Word8"
    SWord16 -> "Word16"
    SWord32 -> "Word32"
    SWord64 -> "Word64"
    SInt8 -> "Int8"
    SInt16 -> "Int16"
    SInt32 -> "Int32"
    SInt64 -> "Int64"
    SInteger -> "Integer"
    SFloat -> "Float"
    SDouble -> "Double"
    SBytes -> "ByteString"
    SText -> "Text"
    SUTCTime -> "UTCTime"
    SVector s -> "[" <> pretty s <> "]"
    SProduct ss -> tupled $ map pretty (V.toList ss)
    SRecord ss -> align $ encloseSep "{ " " }" ", " [pretty k <+> "::" <+> pretty v | (k, v) <- ss]
    SVariant ss -> align $ encloseSep "( " " )" (flatAlt "| " " | ")
      [ nest 2 $ sep [pretty k, pretty vs] | (k, vs) <- ss]
    SFix sch -> group $ nest 2 $ sep ["μ", pretty sch]
    SSelf i -> "Self" <+> pretty i
    STag t s -> nest 2 $ sep [pretty t <> ":", pretty s]

-- | Common representation for any winery data.
-- Handy for prettyprinting winery-serialised data.
data Term = TBool !Bool
  | TChar !Char
  | TWord8 !Word8
  | TWord16 !Word16
  | TWord32 !Word32
  | TWord64 !Word64
  | TInt8 !Int8
  | TInt16 !Int16
  | TInt32 !Int32
  | TInt64 !Int64
  | TInteger !Integer
  | TFloat !Float
  | TDouble !Double
  | TBytes !B.ByteString
  | TText !T.Text
  | TUTCTime !UTCTime
  | TVector (V.Vector Term)
  | TProduct (V.Vector Term)
  | TRecord (V.Vector (T.Text, Term))
  | TVariant !Int !T.Text Term
  deriving Show

data ExtractException = InvalidTerm !Term deriving Show
instance Exception ExtractException

instance J.ToJSON Term where
  toJSON (TBool b) = J.toJSON b
  toJSON (TChar c) = J.toJSON c
  toJSON (TWord8 w) = J.toJSON w
  toJSON (TWord16 w) = J.toJSON w
  toJSON (TWord32 w) = J.toJSON w
  toJSON (TWord64 w) = J.toJSON w
  toJSON (TInt8 w) = J.toJSON w
  toJSON (TInt16 w) = J.toJSON w
  toJSON (TInt32 w) = J.toJSON w
  toJSON (TInt64 w) = J.toJSON w
  toJSON (TInteger w) = J.toJSON w
  toJSON (TFloat x) = J.toJSON x
  toJSON (TDouble x) = J.toJSON x
  toJSON (TBytes bs) = J.toJSON (B.unpack bs)
  toJSON (TText t) = J.toJSON t
  toJSON (TUTCTime t) = J.toJSON t
  toJSON (TVector xs) = J.toJSON xs
  toJSON (TProduct xs) = J.toJSON xs
  toJSON (TRecord xs) = J.toJSON $ HM.fromList $ V.toList xs
  toJSON (TVariant _ "Just" x) = J.toJSON x
  toJSON (TVariant _ "Nothing" _) = J.Null
  toJSON (TVariant _ t x) = J.object ["tag" J..= J.toJSON t, "contents" J..= J.toJSON x]

-- | Deserialiser for a 'Term'.
decodeTerm :: Schema -> Decoder Term
decodeTerm = go [] where
  go points = \case
    SSchema ver -> go points (bootstrapSchema ver)
    SBool -> TBool <$> decodeCurrent
    Data.Winery.SChar -> TChar <$> decodeCurrent
    SWord8 -> TWord8 <$> getWord8
    SWord16 -> TWord16 <$> getWord16
    SWord32 -> TWord32 <$> getWord32
    SWord64 -> TWord64 <$> getWord64
    SInt8 -> TInt8 <$> decodeCurrent
    SInt16 -> TInt16 <$> decodeCurrent
    SInt32 -> TInt32 <$> decodeCurrent
    SInt64 -> TInt64 <$> decodeCurrent
    SInteger -> TInteger <$> decodeVarInt
    SFloat -> TFloat <$> decodeCurrent
    SDouble -> TDouble <$> decodeCurrent
    SBytes -> TBytes <$> decodeCurrent
    Data.Winery.SText -> TText <$> decodeCurrent
    SUTCTime -> TUTCTime <$> decodeCurrent
    SVector sch -> do
      n <- decodeVarInt
      TVector <$> V.replicateM n (go points sch)
    SProduct schs -> TProduct <$> traverse (go points) schs
    SRecord schs -> TRecord <$> traverse (\(k, s) -> (,) k <$> go points s) (V.fromList schs)
    SVariant schs -> do
      let !decoders = V.fromList $ map (\(name, sch) -> let !m = go points sch in (name, m)) schs
      tag <- decodeVarInt
      let (name, dec) = maybe (throw InvalidTag) id $ decoders V.!? tag
      TVariant tag name <$> dec
    SSelf i -> indexDefault (throw InvalidTag) points $ fromIntegral i
    SFix s' -> fix $ \a -> go (a : points) s'
    STag _ s -> go points s

-- | Deserialise a 'serialise'd 'B.Bytestring'.
deserialiseTerm :: B.ByteString -> Either (Doc AnsiStyle) (Schema, Term)
deserialiseTerm bs_ = do
  (sch, bs) <- splitSchema bs_
  return (sch, decodeTerm sch `evalDecoder` bs)

instance Pretty Term where
  pretty (TWord8 i) = pretty i
  pretty (TWord16 i) = pretty i
  pretty (TWord32 i) = pretty i
  pretty (TWord64 i) = pretty i
  pretty (TInt8 i) = pretty i
  pretty (TInt16 i) = pretty i
  pretty (TInt32 i) = pretty i
  pretty (TInt64 i) = pretty i
  pretty (TInteger i) = pretty i
  pretty (TBytes s) = pretty $ show s
  pretty (TText s) = pretty s
  pretty (TVector xs) = list $ map pretty (V.toList xs)
  pretty (TBool x) = pretty x
  pretty (TChar x) = pretty x
  pretty (TFloat x) = pretty x
  pretty (TDouble x) = pretty x
  pretty (TProduct xs) = tupled $ map pretty (V.toList xs)
  pretty (TRecord xs) = align $ encloseSep "{ " " }" ", " [group $ nest 2 $ vsep [pretty k <+> "=", pretty v] | (k, v) <- V.toList xs]
  pretty (TVariant _ tag x) = group $ nest 2 $ sep [pretty tag, pretty x]
  pretty (TUTCTime t) = pretty (show t)

-- | 'Extractor' is a 'Plan' that creates a function from Term.
newtype Extractor a = Extractor { getExtractor :: Plan (Term -> a) }
  deriving Functor

instance Applicative Extractor where
  pure = Extractor . pure . pure
  Extractor f <*> Extractor x = Extractor $ (<*>) <$> f <*> x

instance Alternative Extractor where
  empty = Extractor empty
  Extractor f <|> Extractor g = Extractor $ f <|> g

type Strategy' = Strategy (Term -> Dynamic)

newtype Plan a = Plan { unPlan :: Schema -> Strategy' a }
  deriving Functor

instance Applicative Plan where
  pure = return
  (<*>) = ap

instance Monad Plan where
  return = Plan . const . pure
  m >>= k = Plan $ \sch -> Strategy $ \decs -> case unStrategy (unPlan m sch) decs of
    Right a -> unStrategy (unPlan (k a) sch) decs
    Left e -> Left e

instance Alternative Plan where
  empty = Plan $ const empty
  Plan a <|> Plan b = Plan $ \s -> a s <|> b s

unwrapExtractor :: Extractor a -> Schema -> Strategy' (Term -> a)
unwrapExtractor (Extractor m) = unPlan m
{-# INLINE unwrapExtractor #-}

-- | Serialisable datatype
class Typeable a => Serialise a where
  -- | Obtain the schema of the datatype. @[TypeRep]@ is for handling recursion.
  schemaVia :: Proxy a -> [TypeRep] -> Schema

  -- | Serialise a value.
  toBuilder :: a -> BB.Builder

  -- | The 'Extractor'
  extractor :: Extractor a

  -- | Decode a value with the current schema.
  decodeCurrent :: Decoder a

  default schemaVia :: (Generic a, GSerialiseVariant (Rep a)) => Proxy a -> [TypeRep] -> Schema
  schemaVia = gschemaViaVariant
  default toBuilder :: (Generic a, GSerialiseVariant (Rep a)) => a -> BB.Builder
  toBuilder = gtoBuilderVariant
  default extractor :: (Generic a, GSerialiseVariant (Rep a)) => Extractor a
  extractor = gextractorVariant
  default decodeCurrent :: (Generic a, GSerialiseVariant (Rep a)) => Decoder a
  decodeCurrent = gdecodeCurrentVariant

decodeCurrentDefault :: forall a. Serialise a => Decoder a
decodeCurrentDefault = case getDecoderBy extractor (schema (Proxy :: Proxy a)) of
  Left err -> error $ show $ "decodeCurrent: failed to get a decoder from the current schema"
    <+> parens err
  Right a -> a

-- | Obtain the schema of the datatype.
schema :: forall proxy a. Serialise a => proxy a -> Schema
schema _ = schemaVia (Proxy :: Proxy a) []
{-# INLINE schema #-}

-- | Obtain a decoder from a schema.
getDecoder :: forall a. Serialise a => Schema -> Either StrategyError (Decoder a)
getDecoder sch
  | sch == schema (Proxy :: Proxy a) = Right decodeCurrent
  | otherwise = getDecoderBy extractor sch
{-# INLINE getDecoder #-}

-- | Get a decoder from a `Extractor` and a schema.
getDecoderBy :: Extractor a -> Schema -> Either StrategyError (Decoder a)
getDecoderBy (Extractor plan) sch = (\f -> f <$> decodeTerm sch)
  <$> unPlan plan sch `unStrategy` []
{-# INLINE getDecoderBy #-}

-- | Serialise a value along with its schema.
serialise :: Serialise a => a -> B.ByteString
serialise = BL.toStrict . BB.toLazyByteString . toBuilderWithSchema
{-# INLINE serialise #-}

-- | Serialise a value along with its schema.
writeFileSerialise :: Serialise a => FilePath -> a -> IO ()
writeFileSerialise path a = withFile path WriteMode
  $ \h -> BB.hPutBuilder h $ toBuilderWithSchema a
{-# INLINE writeFileSerialise #-}

toBuilderWithSchema :: forall a. Serialise a => a -> BB.Builder
toBuilderWithSchema a = mappend (BB.word8 currentSchemaVersion)
  $ toBuilder (schema (Proxy :: Proxy a), a)
{-# INLINE toBuilderWithSchema #-}

splitSchema :: B.ByteString -> Either StrategyError (Schema, B.ByteString)
splitSchema bs_ = case B.uncons bs_ of
  Just (ver, bs) -> do
    m <- getDecoder $ SSchema ver
    return $ flip evalDecoder bs $ do
      sch <- m
      Decoder $ \bs' -> ((sch, bs'), mempty)
  Nothing -> Left "Unexpected empty string"

-- | Deserialise a 'serialise'd 'B.Bytestring'.
deserialise :: forall a. Serialise a => B.ByteString -> Either StrategyError a
deserialise bs_ = do
  (sch, bs) <- splitSchema bs_
  if sch == schema (Proxy :: Proxy a)
    then return $ evalDecoder decodeCurrent bs
    else do
      ext <- extractor `unwrapExtractor` sch `unStrategy` []
      return $ ext $ evalDecoder (decodeTerm sch) bs
{-# INLINE deserialise #-}

-- | Deserialise a 'serialise'd 'B.Bytestring'.
deserialiseBy :: Extractor a -> B.ByteString -> Either StrategyError a
deserialiseBy d bs_ = do
  (sch, bs) <- splitSchema bs_
  ext <- d `unwrapExtractor` sch `unStrategy` []
  return $ ext $ evalDecoder (decodeTerm sch) bs

-- | Serialise a value without its schema.
serialiseOnly :: Serialise a => a -> B.ByteString
serialiseOnly = BL.toStrict . BB.toLazyByteString . toBuilder
{-# INLINE serialiseOnly #-}

substSchema :: Serialise a => Proxy a -> [TypeRep] -> Schema
substSchema p ts
  | Just i <- elemIndex (typeRep p) ts = SSelf $ fromIntegral i
  | otherwise = schemaVia p ts

currentSchemaVersion :: Word8
currentSchemaVersion = 3

bootstrapSchema :: Word8 -> Schema
bootstrapSchema 3 = SFix $ SVariant [("SFix",SProduct [SSelf 0])
  ,("SSelf",SProduct [SWord8])
  ,("SVector",SProduct [SSelf 0])
  ,("SProduct",SProduct [SVector (SSelf 0)])
  ,("SRecord",SProduct [SVector (SProduct [SText,SSelf 0])])
  ,("SVariant",SProduct [SVector (SProduct [SText,SSelf 0])])
  ,("SSchema",SProduct [SWord8])
  ,("SBool",SProduct [])
  ,("SChar",SProduct [])
  ,("SWord8",SProduct [])
  ,("SWord16",SProduct [])
  ,("SWord32",SProduct [])
  ,("SWord64",SProduct [])
  ,("SInt8",SProduct [])
  ,("SInt16",SProduct [])
  ,("SInt32",SProduct [])
  ,("SInt64",SProduct [])
  ,("SInteger",SProduct [])
  ,("SFloat",SProduct [])
  ,("SDouble",SProduct [])
  ,("SBytes",SProduct [])
  ,("SText",SProduct [])
  ,("SUTCTime",SProduct [])
  ,("STag",SProduct [stag, SSelf 0])]
  where
    stag = SFix $ SVariant
      [("TagInt",SProduct [SInteger])
      ,("TagStr",SProduct [SText])
      ,("TagList",SProduct [SVector (SSelf 0)])]
bootstrapSchema n = error $ "Unsupported version: " <> show n

unexpectedSchema :: forall f a. Serialise a => Doc AnsiStyle -> Schema -> Strategy' (f a)
unexpectedSchema subject actual = unexpectedSchema' subject
  (pretty $ schema (Proxy :: Proxy a)) actual

unexpectedSchema' :: Doc AnsiStyle -> Doc AnsiStyle -> Schema -> Strategy' a
unexpectedSchema' subject expected actual = errorStrategy
  $ annotate bold subject
  <+> "expects" <+> annotate (color Green <> bold) expected
  <+> "but got " <+> pretty actual

instance Serialise Schema where
  schemaVia _ _ = SSchema currentSchemaVersion
  toBuilder = gtoBuilderVariant
  extractor = Extractor $ Plan $ \case
    SSchema n -> unwrapExtractor gextractorVariant (bootstrapSchema n)
    s -> unwrapExtractor gextractorVariant s
  decodeCurrent = gdecodeCurrentVariant

instance Serialise () where
  schemaVia _ _ = SProduct []
  toBuilder = mempty
  {-# INLINE toBuilder #-}
  extractor = pure ()
  decodeCurrent = pure ()

instance Serialise Bool where
  schemaVia _ _ = SBool
  toBuilder False = BB.word8 0
  toBuilder True = BB.word8 1
  {-# INLINE toBuilder #-}
  extractor = Extractor $ Plan $ \case
    SBool -> pure $ \case
      TBool b -> b
      t -> throw $ InvalidTerm t
    s -> unexpectedSchema "Serialise Bool" s
  decodeCurrent = (/=0) <$> getWord8

instance Serialise Word8 where
  schemaVia _ _ = SWord8
  toBuilder = BB.word8
  {-# INLINE toBuilder #-}
  extractor = Extractor $ Plan $ \case
    SWord8 -> pure $ \case
      TWord8 i -> i
      t -> throw $ InvalidTerm t
    s -> unexpectedSchema "Serialise Word8" s
  decodeCurrent = getWord8

instance Serialise Word16 where
  schemaVia _ _ = SWord16
  toBuilder = BB.word16LE
  {-# INLINE toBuilder #-}
  extractor = Extractor $ Plan $ \case
    SWord16 -> pure $ \case
      TWord16 i -> i
      t -> throw $ InvalidTerm t
    s -> unexpectedSchema "Serialise Word16" s
  decodeCurrent = getWord16

instance Serialise Word32 where
  schemaVia _ _ = SWord32
  toBuilder = BB.word32LE
  {-# INLINE toBuilder #-}
  extractor = Extractor $ Plan $ \case
    SWord32 -> pure $ \case
      TWord32 i -> i
      t -> throw $ InvalidTerm t
    s -> unexpectedSchema "Serialise Word32" s
  decodeCurrent = getWord32

instance Serialise Word64 where
  schemaVia _ _ = SWord64
  toBuilder = BB.word64LE
  {-# INLINE toBuilder #-}
  extractor = Extractor $ Plan $ \case
    SWord64 -> pure $ \case
      TWord64 i -> i
      t -> throw $ InvalidTerm t
    s -> unexpectedSchema "Serialise Word64" s
  decodeCurrent = getWord64

instance Serialise Word where
  schemaVia _ _ = SWord64
  toBuilder = BB.word64LE . fromIntegral
  {-# INLINE toBuilder #-}
  extractor = Extractor $ Plan $ \case
    SWord64 -> pure $ \case
      TWord64 i -> fromIntegral i
      t -> throw $ InvalidTerm t
    s -> unexpectedSchema "Serialise Word" s
  decodeCurrent = fromIntegral <$> getWord64

instance Serialise Int8 where
  schemaVia _ _ = SInt8
  toBuilder = BB.word8 . fromIntegral
  {-# INLINE toBuilder #-}
  extractor = Extractor $ Plan $ \case
    SInt8 -> pure $ \case
      TInt8 i -> i
      t -> throw $ InvalidTerm t
    s -> unexpectedSchema "Serialise Int8" s
  decodeCurrent = fromIntegral <$> getWord8

instance Serialise Int16 where
  schemaVia _ _ = SInt16
  toBuilder = BB.word16LE . fromIntegral
  {-# INLINE toBuilder #-}
  extractor = Extractor $ Plan $ \case
    SInt16 -> pure $ \case
      TInt16 i -> i
      t -> throw $ InvalidTerm t
    s -> unexpectedSchema "Serialise Int16" s
  decodeCurrent = fromIntegral <$> getWord16

instance Serialise Int32 where
  schemaVia _ _ = SInt32
  toBuilder = BB.word32LE . fromIntegral
  {-# INLINE toBuilder #-}
  extractor = Extractor $ Plan $ \case
    SInt32 -> pure $ \case
      TInt32 i -> i
      t -> throw $ InvalidTerm t
    s -> unexpectedSchema "Serialise Int32" s
  decodeCurrent = fromIntegral <$> getWord32

instance Serialise Int64 where
  schemaVia _ _ = SInt64
  toBuilder = BB.word64LE . fromIntegral
  {-# INLINE toBuilder #-}
  extractor = Extractor $ Plan $ \case
    SInt64 -> pure $ \case
      TInt64 i -> i
      t -> throw $ InvalidTerm t
    s -> unexpectedSchema "Serialise Int64" s
  decodeCurrent = fromIntegral <$> getWord64

instance Serialise Int where
  schemaVia _ _ = SInteger
  toBuilder = toBuilder . VarInt
  {-# INLINE toBuilder #-}
  extractor = Extractor $ Plan $ \case
    SInteger -> pure $ \case
      TInteger i -> fromIntegral i
      t -> throw $ InvalidTerm t
    s -> unexpectedSchema "Serialise Int" s
  decodeCurrent = decodeVarInt

instance Serialise Float where
  schemaVia _ _ = SFloat
  toBuilder = BB.word32LE . unsafeCoerce
  {-# INLINE toBuilder #-}
  extractor = Extractor $ Plan $ \case
    SFloat -> pure $ \case
      TFloat x -> x
      t -> throw $ InvalidTerm t
    s -> unexpectedSchema "Serialise Float" s
  decodeCurrent = unsafeCoerce getWord32

instance Serialise Double where
  schemaVia _ _ = SDouble
  toBuilder = BB.doubleLE
  {-# INLINE toBuilder #-}
  extractor = Extractor $ Plan $ \case
    SDouble -> pure $ \case
      TDouble x -> x
      t -> throw $ InvalidTerm t
    s -> unexpectedSchema "Serialise Double" s
  decodeCurrent = unsafeCoerce getWord64

instance Serialise T.Text where
  schemaVia _ _ = SText
  toBuilder = toBuilder . T.encodeUtf8
  {-# INLINE toBuilder #-}
  extractor = Extractor $ Plan $ \case
    SText -> pure $ \case
      TText t -> t
      t -> throw $ InvalidTerm t
    s -> unexpectedSchema "Serialise Text" s
  decodeCurrent = do
    len <- decodeVarInt
    T.decodeUtf8 <$> Decoder (B.splitAt len)

-- | Encoded in variable-length quantity.
newtype VarInt a = VarInt { getVarInt :: a } deriving (Show, Read, Eq, Ord, Enum
  , Bounded, Num, Real, Integral, Bits, Typeable)

instance (Typeable a, Bits a, Integral a) => Serialise (VarInt a) where
  schemaVia _ _ = SInteger
  toBuilder = varInt . getVarInt
  {-# INLINE toBuilder #-}
  extractor = Extractor $ Plan $ \case
    SInteger -> pure $ \case
      TInteger i -> fromIntegral i
      t -> throw $ InvalidTerm t
    s -> unexpectedSchema "Serialise (VarInt a)" s
  decodeCurrent = VarInt <$> decodeVarInt

instance Serialise Integer where
  schemaVia _ _ = SInteger
  toBuilder = toBuilder . VarInt
  {-# INLINE toBuilder #-}
  extractor = getVarInt <$> extractor
  decodeCurrent = getVarInt <$> decodeCurrent

instance Serialise Char where
  schemaVia _ _ = SChar
  toBuilder = toBuilder . fromEnum
  {-# INLINE toBuilder #-}
  extractor = Extractor $ Plan $ \case
    SChar -> pure $ \case
      TChar c -> c
      t -> throw $ InvalidTerm t
    s -> unexpectedSchema "Serialise Char" s
  decodeCurrent = toEnum <$> decodeVarInt

instance Serialise a => Serialise (Maybe a) where
  schemaVia _ ts = SVariant [("Nothing", SProduct [])
    , ("Just", substSchema (Proxy :: Proxy a) ts)]
  toBuilder Nothing = varInt (0 :: Word8)
  toBuilder (Just a) = varInt (1 :: Word8) <> toBuilder a
  {-# INLINE toBuilder #-}
  extractor = Extractor $ Plan $ \case
    SVariant [_, (_, sch)] -> do
      dec <- unwrapExtractor extractor sch
      return $ \case
        TVariant 0 _ _ -> Nothing
        TVariant _ _ v -> Just $ dec v
        t -> throw $ InvalidTerm t
    s -> unexpectedSchema "Serialise (Maybe a)" s
  decodeCurrent = getWord8 >>= \case
    0 -> pure Nothing
    _ -> Just <$> decodeCurrent

instance Serialise B.ByteString where
  schemaVia _ _ = SBytes
  toBuilder bs = varInt (B.length bs) <> BB.byteString bs
  {-# INLINE toBuilder #-}
  extractor = Extractor $ Plan $ \case
    SBytes -> pure $ \case
      TBytes bs -> bs
      t -> throw $ InvalidTerm t
    s -> unexpectedSchema "Serialise ByteString" s
  decodeCurrent = do
    len <- decodeVarInt
    Decoder (B.splitAt len)

instance Serialise BL.ByteString where
  schemaVia _ _ = SBytes
  toBuilder = toBuilder . BL.toStrict
  {-# INLINE toBuilder #-}
  extractor = BL.fromStrict <$> extractor
  decodeCurrent = BL.fromStrict <$> decodeCurrent

instance Serialise UTCTime where
  schemaVia _ _ = SUTCTime
  toBuilder = toBuilder . utcTimeToPOSIXSeconds
  {-# INLINE toBuilder #-}
  extractor = Extractor $ Plan $ \case
    SUTCTime -> unwrapExtractor
      (posixSecondsToUTCTime <$> extractor)
      (schema (Proxy :: Proxy Double))
    s -> unexpectedSchema "Serialise UTCTime" s
  decodeCurrent = posixSecondsToUTCTime <$> unsafeCoerce getWord64

instance Serialise NominalDiffTime where
  schemaVia _ = schemaVia (Proxy :: Proxy Double)
  toBuilder = toBuilder . (realToFrac :: NominalDiffTime -> Double)
  {-# INLINE toBuilder #-}
  extractor = (realToFrac :: Double -> NominalDiffTime) <$> extractor
  decodeCurrent = (realToFrac :: Double -> NominalDiffTime) <$> decodeCurrent

instance Serialise a => Serialise [a] where
  schemaVia _ ts = SVector (substSchema (Proxy :: Proxy a) ts)
  toBuilder xs = varInt (length xs)
      <> foldMap toBuilder xs
  {-# INLINE toBuilder #-}
  extractor = V.toList <$> extractListBy extractor
  decodeCurrent = do
    n <- decodeVarInt
    replicateM n decodeCurrent

instance Serialise a => Serialise (V.Vector a) where
  schemaVia _ = schemaVia (Proxy :: Proxy [a])
  toBuilder xs = varInt (V.length xs)
    <> foldMap toBuilder xs
  {-# INLINE toBuilder #-}
  extractor = extractListBy extractor
  decodeCurrent = do
    n <- decodeVarInt
    V.replicateM n decodeCurrent

instance (SV.Storable a, Serialise a) => Serialise (SV.Vector a) where
  schemaVia _ = schemaVia (Proxy :: Proxy [a])
  toBuilder = toBuilder . (SV.convert :: SV.Vector a -> V.Vector a)
  {-# INLINE toBuilder #-}
  extractor = SV.convert <$> extractListBy extractor
  decodeCurrent = do
    n <- decodeVarInt
    SV.replicateM n decodeCurrent

instance (UV.Unbox a, Serialise a) => Serialise (UV.Vector a) where
  schemaVia _ = schemaVia (Proxy :: Proxy [a])
  toBuilder = toBuilder . (UV.convert :: UV.Vector a -> V.Vector a)
  {-# INLINE toBuilder #-}
  extractor = UV.convert <$> extractListBy extractor
  decodeCurrent = do
    n <- decodeVarInt
    UV.replicateM n decodeCurrent

-- | Extract a list or an array of values.
extractListBy :: Extractor a -> Extractor (V.Vector a)
extractListBy (Extractor plan) = Extractor $ Plan $ \case
  SVector s -> do
    getItem <- unPlan plan s
    return $ \case
      TVector xs -> V.map getItem xs
      t -> throw $ InvalidTerm t
  s -> unexpectedSchema' "extractListBy ..." "[a]" s
{-# INLINE extractListBy #-}

instance (Ord k, Serialise k, Serialise v) => Serialise (M.Map k v) where
  schemaVia _ = schemaVia (Proxy :: Proxy [(k, v)])
  toBuilder = toBuilder . M.toList
  {-# INLINE toBuilder #-}
  extractor = M.fromList <$> extractor
  decodeCurrent = M.fromList <$> decodeCurrent

instance (Eq k, Hashable k, Serialise k, Serialise v) => Serialise (HM.HashMap k v) where
  schemaVia _ = schemaVia (Proxy :: Proxy [(k, v)])
  toBuilder = toBuilder . HM.toList
  {-# INLINE toBuilder #-}
  extractor = HM.fromList <$> extractor
  decodeCurrent = HM.fromList <$> decodeCurrent

instance (Serialise v) => Serialise (IM.IntMap v) where
  schemaVia _ = schemaVia (Proxy :: Proxy [(Int, v)])
  toBuilder = toBuilder . IM.toList
  {-# INLINE toBuilder #-}
  extractor = IM.fromList <$> extractor
  decodeCurrent = IM.fromList <$> decodeCurrent

instance (Ord a, Serialise a) => Serialise (S.Set a) where
  schemaVia _ = schemaVia (Proxy :: Proxy [a])
  toBuilder = toBuilder . S.toList
  {-# INLINE toBuilder #-}
  extractor = S.fromList <$> extractor
  decodeCurrent = S.fromList <$> decodeCurrent

instance Serialise IS.IntSet where
  schemaVia _ = schemaVia (Proxy :: Proxy [Int])
  toBuilder = toBuilder . IS.toList
  {-# INLINE toBuilder #-}
  extractor = IS.fromList <$> extractor
  decodeCurrent = IS.fromList <$> decodeCurrent

instance Serialise a => Serialise (Seq.Seq a) where
  schemaVia _ = schemaVia (Proxy :: Proxy [a])
  toBuilder = toBuilder . Data.Foldable.toList
  {-# INLINE toBuilder #-}
  extractor = Seq.fromList <$> extractor
  decodeCurrent = Seq.fromList <$> decodeCurrent

instance Serialise Scientific where
  schemaVia _ = schemaVia (Proxy :: Proxy (Integer, Int))
  toBuilder s = toBuilder (coefficient s, base10Exponent s)
  {-# INLINE toBuilder #-}
  extractor = Extractor $ Plan $ \s -> case s of
    SWord8 -> f (fromIntegral :: Word8 -> Scientific) s
    SWord16 -> f (fromIntegral :: Word16 -> Scientific) s
    SWord32 -> f (fromIntegral :: Word32 -> Scientific) s
    SWord64 -> f (fromIntegral :: Word64 -> Scientific) s
    SInt8 -> f (fromIntegral :: Int8 -> Scientific) s
    SInt16 -> f (fromIntegral :: Int16 -> Scientific) s
    SInt32 -> f (fromIntegral :: Int32 -> Scientific) s
    SInt64 -> f (fromIntegral :: Int64 -> Scientific) s
    SInteger -> f fromInteger s
    SFloat -> f (realToFrac :: Float -> Scientific) s
    SDouble -> f (realToFrac :: Double -> Scientific) s
    _ -> f (uncurry scientific) s
    where
      f c = unwrapExtractor (c <$> extractor)
  decodeCurrent = decodeCurrentDefault

-- | Extract a field of a record.
extractField :: Serialise a => T.Text -> Extractor a
extractField = extractFieldBy extractor
{-# INLINE extractField #-}

-- | Extract a field using the supplied 'Extractor'.
extractFieldBy :: Typeable a => Extractor a -> T.Text -> Extractor a
extractFieldBy (Extractor g) name = Extractor $ handleRecursion $ \case
  SRecord schs -> do
    let schs' = [(k, (i, s)) | (i, (k, s)) <- zip [0..] schs]
    case lookup name schs' of
      Just (i, sch) -> do
        m <- unPlan g sch
        return $ \case
          TRecord xs -> maybe (error msg) (m . snd) $ xs V.!? i
          t -> throw $ InvalidTerm t
      Nothing -> errorStrategy $ rep <> ": Schema not found in " <> pretty (map fst schs)
  s -> unexpectedSchema' rep "a record" s
  where
    rep = "extractFieldBy ... " <> dquotes (pretty name)
    msg = "Data.Winery.extractFieldBy ... " <> show name <> ": impossible"

handleRecursion :: Typeable a => (Schema -> Strategy' (Term -> a)) -> Plan (Term -> a)
handleRecursion k = Plan $ \sch -> Strategy $ \decs -> case sch of
  SSelf i -> return $ fmap (`fromDyn` throw InvalidTag)
    $ indexDefault (error "Data.Winery.handleRecursion: unbound fixpoint") decs (fromIntegral i)
  SFix s -> mfix $ \a -> unPlan (handleRecursion k) s `unStrategy` (fmap toDyn a : decs)
  s -> k s `unStrategy` decs

instance (Serialise a, Serialise b) => Serialise (a, b) where
  schemaVia _ ts = SProduct [substSchema (Proxy :: Proxy a) ts, substSchema (Proxy :: Proxy b) ts]
  toBuilder (a, b) = toBuilder a <> toBuilder b
  {-# INLINE toBuilder #-}
  extractor = Extractor $ Plan $ \case
    SProduct [sa, sb] -> do
      getA <- unwrapExtractor extractor sa
      getB <- unwrapExtractor extractor sb
      return $ \case
        TProduct [a, b] -> (getA a, getB b)
        t -> throw $ InvalidTerm t
    s -> unexpectedSchema "Serialise (a, b)" s
  decodeCurrent = (,) <$> decodeCurrent <*> decodeCurrent

instance (Serialise a, Serialise b, Serialise c) => Serialise (a, b, c) where
  schemaVia _ ts = SProduct [sa, sb, sc]
    where
      sa = substSchema (Proxy :: Proxy a) ts
      sb = substSchema (Proxy :: Proxy b) ts
      sc = substSchema (Proxy :: Proxy c) ts
  toBuilder (a, b, c) = toBuilder a <> toBuilder b <> toBuilder c
  {-# INLINE toBuilder #-}
  extractor = Extractor $ Plan $ \case
    SProduct [sa, sb, sc] -> do
      getA <- unwrapExtractor extractor sa
      getB <- unwrapExtractor extractor sb
      getC <- unwrapExtractor extractor sc
      return $ \case
        TProduct [a, b, c] -> (getA a, getB b, getC c)
        t -> throw $ InvalidTerm t
    s -> unexpectedSchema "Serialise (a, b, c)" s
  decodeCurrent = (,,) <$> decodeCurrent <*> decodeCurrent <*> decodeCurrent

instance (Serialise a, Serialise b, Serialise c, Serialise d) => Serialise (a, b, c, d) where
  schemaVia _ ts = SProduct [sa, sb, sc, sd]
    where
      sa = substSchema (Proxy :: Proxy a) ts
      sb = substSchema (Proxy :: Proxy b) ts
      sc = substSchema (Proxy :: Proxy c) ts
      sd = substSchema (Proxy :: Proxy d) ts
  toBuilder (a, b, c, d) = toBuilder a <> toBuilder b <> toBuilder c <> toBuilder d
  {-# INLINE toBuilder #-}
  extractor = Extractor $ Plan $ \case
    SProduct [sa, sb, sc, sd] -> do
      getA <- unwrapExtractor extractor sa
      getB <- unwrapExtractor extractor sb
      getC <- unwrapExtractor extractor sc
      getD <- unwrapExtractor extractor sd
      return $ \case
        TProduct [a, b, c, d] -> (getA a, getB b, getC c, getD d)
        t -> throw $ InvalidTerm t
    s -> unexpectedSchema "Serialise (a, b, c, d)" s
  decodeCurrent = (,,,) <$> decodeCurrent <*> decodeCurrent <*> decodeCurrent <*> decodeCurrent

instance (Serialise a, Serialise b) => Serialise (Either a b) where
  schemaVia _ ts = SVariant [("Left", substSchema (Proxy :: Proxy a) ts)
    , ("Right", substSchema (Proxy :: Proxy b) ts)]
  toBuilder (Left a) = BB.word8 0 <> toBuilder a
  toBuilder (Right b) = BB.word8 1 <> toBuilder b
  {-# INLINE toBuilder #-}
  extractor = Extractor $ Plan $ \case
    SVariant [(_, sa), (_, sb)] -> do
      getA <- unwrapExtractor extractor sa
      getB <- unwrapExtractor extractor sb
      return $ \case
        TVariant 0 _ v -> Left $ getA v
        TVariant _ _ v -> Right $ getB v
        t -> throw $ InvalidTerm t
    s -> unexpectedSchema "Either (a, b)" s
  decodeCurrent = getWord8 >>= \case
    0 -> Left <$> decodeCurrent
    _ -> Right <$> decodeCurrent

-- | Tries to extract a specific constructor of a variant. Useful for
-- implementing backward-compatible extractors.
extractConstructorBy :: Typeable a => Extractor a -> T.Text -> Extractor (Maybe a)
extractConstructorBy d name = Extractor $ handleRecursion $ \case
  SVariant schs0 -> Strategy $ \decs -> do
    (j, dec) <- case [(i :: Int, ss) | (i, (k, ss)) <- zip [0..] schs0, name == k] of
      [(i, s)] -> fmap ((,) i) $ unwrapExtractor d s `unStrategy` decs
      _ -> Left $ rep <> ": Schema not found in " <> pretty (map fst schs0)

    return $ \case
      TVariant i _ v
        | i == j -> Just $ dec v
        | otherwise -> Nothing
      t -> throw $ InvalidTerm t
  s -> unexpectedSchema' rep "a variant" s
  where
    rep = "extractConstructorBy ... " <> dquotes (pretty name)

extractConstructor :: (Serialise a) => T.Text -> Extractor (Maybe a)
extractConstructor = extractConstructorBy extractor
{-# INLINE extractConstructor #-}

-- | Generic implementation of 'schemaVia' for a record.
gschemaViaRecord :: forall proxy a. (GSerialiseRecord (Rep a), Generic a, Typeable a) => proxy a -> [TypeRep] -> Schema
gschemaViaRecord p ts = SFix $ SRecord $ recordSchema (Proxy :: Proxy (Rep a)) (typeRep p : ts)

-- | Generic implementation of 'toBuilder' for a record.
gtoBuilderRecord :: (GEncodeRecord (Rep a), Generic a) => a -> BB.Builder
gtoBuilderRecord = recordEncoder . from
{-# INLINE gtoBuilderRecord #-}

data FieldDecoder i a = FieldDecoder !i !(Maybe a) !(Plan (Term -> a))

-- | Generic implementation of 'extractor' for a record.
gextractorRecord :: forall a. (GSerialiseRecord (Rep a), Generic a, Typeable a)
  => Maybe a -- ^ default value (optional)
  -> Extractor a
gextractorRecord def = Extractor $ handleRecursion $ \case
  SRecord schs -> Strategy $ \decs -> do
    let schs' = [(k, (i, s)) | (i, (k, s)) <- zip [0..] schs]
    let go :: FieldDecoder T.Text x -> Either StrategyError (Term -> x)
        go (FieldDecoder name def' p) = case lookup name schs' of
          Nothing -> case def' of
            Just d -> Right (const d)
            Nothing -> Left $ rep <> ": Default value not found for " <> pretty name
          Just (i, sch) -> case p `unPlan` sch `unStrategy` decs of
            Right getItem -> Right $ \case
              TRecord xs -> maybe (error (show rep)) (getItem . snd) $ xs V.!? i
              t -> throw $ InvalidTerm t
            Left e -> Left e
    m <- unTransFusion (recordExtractor $ from <$> def) go
    return (to . m)
  s -> unexpectedSchema' rep "a record" s
  where
    rep = "gextractorRecord :: Extractor "
      <> viaShow (typeRep (Proxy :: Proxy a))
{-# INLINE gextractorRecord #-}

gdecodeCurrentRecord :: (GSerialiseRecord (Rep a), Generic a) => Decoder a
gdecodeCurrentRecord = to <$> recordDecoder
{-# INLINE gdecodeCurrentRecord #-}

newtype WineryRecord a = WineryRecord { unWineryRecord :: a }

instance (GEncodeRecord (Rep a), GSerialiseRecord (Rep a), Generic a, Typeable a) => Serialise (WineryRecord a) where
  schemaVia _ = gschemaViaRecord (Proxy :: Proxy a)
  toBuilder = gtoBuilderRecord . unWineryRecord
  extractor = WineryRecord <$> gextractorRecord Nothing
  decodeCurrent = WineryRecord <$> gdecodeCurrentRecord

class GEncodeRecord f where
  recordEncoder :: f x -> BB.Builder

instance (GEncodeRecord f, GEncodeRecord g) => GEncodeRecord (f :*: g) where
  recordEncoder (f :*: g) = recordEncoder f <> recordEncoder g
  {-# INLINE recordEncoder #-}

instance Serialise a => GEncodeRecord (S1 c (K1 i a)) where
  recordEncoder (M1 (K1 a)) = toBuilder a
  {-# INLINE recordEncoder #-}

instance GEncodeRecord f => GEncodeRecord (C1 c f) where
  recordEncoder (M1 a) = recordEncoder a
  {-# INLINE recordEncoder #-}

instance GEncodeRecord f => GEncodeRecord (D1 c f) where
  recordEncoder (M1 a) = recordEncoder a
  {-# INLINE recordEncoder #-}

class GSerialiseRecord f where
  recordSchema :: proxy f -> [TypeRep] -> [(T.Text, Schema)]
  recordExtractor :: Maybe (f x) -> TransFusion (FieldDecoder T.Text) ((->) Term) (Term -> f x)
  recordDecoder :: Decoder (f x)

instance (GSerialiseRecord f, GSerialiseRecord g) => GSerialiseRecord (f :*: g) where
  recordSchema _ ts = recordSchema (Proxy :: Proxy f) ts
    ++ recordSchema (Proxy :: Proxy g) ts
  recordExtractor def = (\f g -> (:*:) <$> f <*> g)
    <$> recordExtractor ((\(x :*: _) -> x) <$> def)
    <*> recordExtractor ((\(_ :*: x) -> x) <$> def)
  {-# INLINE recordExtractor #-}
  recordDecoder = (:*:) <$> recordDecoder <*> recordDecoder
  {-# INLINE recordDecoder #-}

instance (Serialise a, Selector c) => GSerialiseRecord (S1 c (K1 i a)) where
  recordSchema _ ts = [(T.pack $ selName (M1 undefined :: M1 i c (K1 i a) x), substSchema (Proxy :: Proxy a) ts)]
  recordExtractor def = TransFusion $ \k -> fmap (fmap (M1 . K1)) $ k $ FieldDecoder
    (T.pack $ selName (M1 undefined :: M1 i c (K1 i a) x))
    (unK1 . unM1 <$> def)
    (getExtractor extractor)
  {-# INLINE recordExtractor #-}
  recordDecoder = M1 . K1 <$> decodeCurrent
  {-# INLINE recordDecoder #-}

instance (GSerialiseRecord f) => GSerialiseRecord (C1 c f) where
  recordSchema _ = recordSchema (Proxy :: Proxy f)
  recordExtractor def = fmap M1 <$> recordExtractor (unM1 <$> def)
  recordDecoder = M1 <$> recordDecoder

instance (GSerialiseRecord f) => GSerialiseRecord (D1 c f) where
  recordSchema _ = recordSchema (Proxy :: Proxy f)
  recordExtractor def = fmap M1 <$> recordExtractor (unM1 <$> def)
  recordDecoder = M1 <$> recordDecoder

class GSerialiseProduct f where
  productSchema :: proxy f -> [TypeRep] -> [Schema]
  productEncoder :: f x -> BB.Builder
  productExtractor :: Compose (State Int) (TransFusion (FieldDecoder Int) ((->) Term)) (Term -> f x)
  productDecoder :: Decoder (f x)

instance GSerialiseProduct U1 where
  productSchema _ _ = []
  productEncoder _ = mempty
  productExtractor = pure (pure U1)
  productDecoder = pure U1

instance (Serialise a) => GSerialiseProduct (K1 i a) where
  productSchema _ ts = [substSchema (Proxy :: Proxy a) ts]
  productEncoder (K1 a) = toBuilder a
  productExtractor = Compose $ state $ \i ->
    ( TransFusion $ \k -> fmap (fmap K1) $ k $ FieldDecoder i Nothing (getExtractor extractor)
    , i + 1)
  productDecoder = K1 <$> decodeCurrent

instance GSerialiseProduct f => GSerialiseProduct (M1 i c f) where
  productSchema _ ts = productSchema (Proxy :: Proxy f) ts
  productEncoder (M1 a) = productEncoder a
  productExtractor = fmap M1 <$> productExtractor
  productDecoder = M1 <$> productDecoder

instance (GSerialiseProduct f, GSerialiseProduct g) => GSerialiseProduct (f :*: g) where
  productSchema _ ts = productSchema (Proxy :: Proxy f) ts ++ productSchema (Proxy :: Proxy g) ts
  productEncoder (f :*: g) = productEncoder f <> productEncoder g
  productExtractor = liftA2 (:*:) <$> productExtractor <*> productExtractor
  productDecoder = (:*:) <$> productDecoder <*> productDecoder

extractorProduct' :: GSerialiseProduct f => Schema -> Strategy' (Term -> f x)
extractorProduct' (SProduct schs) = Strategy $ \recs -> do
  let go :: FieldDecoder Int x -> Either StrategyError (Term -> x)
      go (FieldDecoder i _ p) = do
        getItem <- if i < length schs
          then unPlan p (schs V.! i) `unStrategy` recs
          else Left "Data.Winery.gextractorProduct: insufficient fields"
        return $ \case
          TProduct xs -> getItem $ maybe (throw $ InvalidTerm (TProduct xs)) id
            $ xs V.!? i
          t -> throw $ InvalidTerm t
  m <- unTransFusion (getCompose productExtractor `evalState` 0) go
  return m
extractorProduct' sch = unexpectedSchema' "extractorProduct'" "a product" sch

-- | Generic implementation of 'schemaVia' for an ADT.
gschemaViaVariant :: forall proxy a. (GSerialiseVariant (Rep a), Typeable a, Generic a) => proxy a -> [TypeRep] -> Schema
gschemaViaVariant p ts = SFix $ SVariant $ variantSchema (Proxy :: Proxy (Rep a)) (typeRep p : ts)

-- | Generic implementation of 'toBuilder' for an ADT.
gtoBuilderVariant :: (GSerialiseVariant (Rep a), Generic a) => a -> BB.Builder
gtoBuilderVariant = variantEncoder 0 . from
{-# INLINE gtoBuilderVariant #-}

-- | Generic implementation of 'extractor' for an ADT.
gextractorVariant :: forall a. (GSerialiseVariant (Rep a), Generic a, Typeable a)
  => Extractor a
gextractorVariant = Extractor $ handleRecursion $ \case
  SVariant schs0 -> Strategy $ \decs -> do
    ds' <- V.fromList <$> sequence
      [ case lookup name variantExtractor of
          Nothing -> Left $ rep <> ": Schema not found for " <> pretty name
          Just f -> f sch `unStrategy` decs
      | (name, sch) <- schs0]
    return $ \case
      TVariant i _ v -> to $ maybe (throw InvalidTag) ($ v) $ ds' V.!? i
      t -> throw $ InvalidTerm t
  s -> unexpectedSchema' rep "a variant" s
  where
    rep = "gextractorVariant :: Extractor "
      <> viaShow (typeRep (Proxy :: Proxy a))

gdecodeCurrentVariant :: (GSerialiseVariant (Rep a), Generic a) => Decoder a
gdecodeCurrentVariant = decodeVarInt >>= maybe (throw InvalidTag) (fmap to) . (decs V.!?)
  where
    decs = V.fromList variantDecoder

class GSerialiseVariant f where
  variantCount :: proxy f -> Int
  variantSchema :: proxy f -> [TypeRep] -> [(T.Text, Schema)]
  variantEncoder :: Int -> f x -> BB.Builder
  variantExtractor :: [(T.Text, Schema -> Strategy' (Term -> f x))]
  variantDecoder :: [Decoder (f x)]

instance (GSerialiseVariant f, GSerialiseVariant g) => GSerialiseVariant (f :+: g) where
  variantCount _ = variantCount (Proxy :: Proxy f) + variantCount (Proxy :: Proxy g)
  variantSchema _ ts = variantSchema (Proxy :: Proxy f) ts ++ variantSchema (Proxy :: Proxy g) ts
  variantEncoder i (L1 f) = variantEncoder i f
  variantEncoder i (R1 g) = variantEncoder (i + variantCount (Proxy :: Proxy f)) g
  variantExtractor = fmap (fmap (fmap (fmap (fmap L1)))) variantExtractor
    ++ fmap (fmap (fmap (fmap (fmap R1)))) variantExtractor
  variantDecoder = fmap (fmap L1) variantDecoder ++ fmap (fmap R1) variantDecoder

instance (GSerialiseProduct f, Constructor c) => GSerialiseVariant (C1 c f) where
  variantCount _ = 1
  variantSchema _ ts = [(T.pack $ conName (M1 undefined :: M1 i c f x), SProduct $ V.fromList $ productSchema (Proxy :: Proxy f) ts)]
  variantEncoder i (M1 a) = varInt i <> productEncoder a
  variantExtractor = [(T.pack $ conName (M1 undefined :: M1 i c f x)
    , fmap (fmap M1) . extractorProduct') ]
  variantDecoder = [M1 <$> productDecoder]

instance (GSerialiseVariant f) => GSerialiseVariant (S1 c f) where
  variantCount _ = variantCount (Proxy :: Proxy f)
  variantSchema _ ts = variantSchema (Proxy :: Proxy f) ts
  variantEncoder i (M1 a) = variantEncoder i a
  variantExtractor = fmap (fmap (fmap (fmap M1))) <$> variantExtractor
  variantDecoder = fmap M1 <$> variantDecoder

instance (GSerialiseVariant f) => GSerialiseVariant (D1 c f) where
  variantCount _ = variantCount (Proxy :: Proxy f)
  variantSchema _ ts = variantSchema (Proxy :: Proxy f) ts
  variantEncoder i (M1 a) = variantEncoder i a
  variantExtractor = fmap (fmap (fmap (fmap M1))) <$> variantExtractor
  variantDecoder = fmap M1 <$> variantDecoder

instance Serialise Ordering
deriving instance Serialise a => Serialise (Identity a)
deriving instance (Serialise a, Typeable b) => Serialise (Const a (b :: *))
