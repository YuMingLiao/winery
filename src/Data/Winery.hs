{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE ExistentialQuantification #-}
module Data.Winery
  ( Schema(..)
  , Serialise(..)
  , schema
  , serialise
  , deserialise
  , deserialiseWith
  , Encoding
  , encodeMulti
  , Decoder
  , Plan
  , extractFieldWith
  , GSerialiseRecord
  , gschemaViaRecord
  , gtoEncodingRecord
  , ggetDecoderViaRecord
  , GSerialiseVariant
  , gschemaViaVariant
  , gtoEncodingVariant
  , ggetDecoderViaVariant
  )where

import Control.Applicative
import Control.Monad
import Control.Monad.Trans.Cont
import Control.Monad.Reader
import Data.ByteString.Builder
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Unsafe as B
import qualified Data.ByteString.Builder as BB
import Data.Bits
import Data.Dynamic
import Data.Functor.Identity
import Data.Proxy
import Data.Int
import Data.List (elemIndex)
import Data.Monoid
import Data.Word
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Typeable
import GHC.Generics
import Unsafe.Coerce

data Schema = SSchema !Word8
  | SUnit
  | SBool
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
  | SList Schema
  | SProduct [Schema]
  | SSum [Schema]
  | SRecord [(T.Text, Schema)]
  | SVariant [(T.Text, [Schema])]
  | SSelf !Word8
  | SFix Schema
  deriving (Show, Read, Eq, Generic)

type Encoding = (Sum Int, Builder)

type Decoder = (->) B.ByteString

type Plan = ReaderT Schema (Either String)

class Typeable a => Serialise a where
  schemaVia :: proxy a -> [TypeRep] -> Schema
  toEncoding :: a -> Encoding
  getDecoderVia :: [Decoder Dynamic] -> Plan (Decoder a)

schema :: Serialise a => proxy a -> Schema
schema p = schemaVia p []

getDecoder :: Serialise a => Plan (Decoder a)
getDecoder = getDecoderVia []

serialise :: Serialise a => a -> B.ByteString
serialise = BL.toStrict . BB.toLazyByteString . snd . toEncoding

deserialiseWith :: Plan (Decoder a) -> Schema -> B.ByteString -> Either String a
deserialiseWith m sch bs = ($ bs) <$> runReaderT m sch

deserialise :: Serialise a => Schema -> B.ByteString -> Either String a
deserialise = deserialiseWith getDecoder

substSchema :: Serialise a => proxy a -> [TypeRep] -> Schema
substSchema p ts
  | Just i <- elemIndex (typeRep p) ts = SSelf $ fromIntegral i
  | otherwise = schemaVia p ts

decodeAt :: Int -> Decoder a -> Decoder a
decodeAt i m bs = m $ B.drop i bs

encodeVarInt :: (Integral a, Bits a) => a -> Encoding
encodeVarInt n
  | n < 0x80 = (1, BB.word8 $ fromIntegral n)
  | otherwise = let (s, b) = encodeVarInt (shiftR n 7)
    in (1 + s, BB.word8 (setBit (fromIntegral n) 7) `mappend` b)

getWord8 :: ContT r Decoder Word8
getWord8 = ContT $ \k bs -> case B.uncons bs of
  Nothing -> k 0 bs
  Just (x, bs') -> k x bs'

getBytes :: Decoder B.ByteString
getBytes = runContT decodeVarInt B.take

decodeVarInt :: (Num a, Bits a) => ContT r Decoder a
decodeVarInt = getWord8 >>= \case
  n | testBit n 7 -> do
      m <- decodeVarInt
      return $! shiftL m 7 .|. clearBit (fromIntegral n) 7
    | otherwise -> return $ fromIntegral n

bootstrapSchema :: Word8 -> Either String Schema
bootstrapSchema 0 = Right $ SFix $ SVariant [("SSchema",[SWord8])
  ,("SUnit",[])
  ,("SBool",[])
  ,("SWord8",[])
  ,("SWord16",[])
  ,("SWord32",[])
  ,("SWord64",[])
  ,("SInt8",[])
  ,("SInt16",[])
  ,("SInt32",[])
  ,("SInt64",[])
  ,("SInteger",[])
  ,("SFloat",[])
  ,("SDouble",[])
  ,("SBytes",[])
  ,("SText",[])
  ,("SList",[SSelf 0])
  ,("SProduct",[SList (SSelf 0)])
  ,("SSum",[SList (SSelf 0)])
  ,("SRecord",[SList (SProduct [SText,SSelf 0])])
  ,("SVariant",[SList (SProduct [SText,SList (SSelf 0)])])
  ,("SSelf",[SWord8])
  ,("SFix",[SSelf 0])]
bootstrapSchema n = Left $ "Unsupported version: " ++ show n

instance Serialise Schema where
  schemaVia _ _ = SSchema 0
  toEncoding = gtoEncodingVariant
  getDecoderVia recs = ReaderT $ \case
    SSchema n -> bootstrapSchema n >>= runReaderT (ggetDecoderViaVariant recs)
    s -> runReaderT (ggetDecoderViaVariant recs) s

instance Serialise () where
  schemaVia _ _ = SUnit
  toEncoding = mempty
  getDecoderVia _ = pure (pure ())

instance Serialise Bool where
  schemaVia _ _ = SBool
  toEncoding False = (1, BB.word8 0)
  toEncoding True = (1, BB.word8 1)
  getDecoderVia _ = ReaderT $ \case
    SBool -> Right $ (/=0) <$> evalContT getWord8
    s -> Left $ "Expected Bool, but got " ++ show s

instance Serialise Word8 where
  schemaVia _ _ = SWord8
  toEncoding x = (1, BB.word8 x)
  getDecoderVia _ = ReaderT $ \case
    SWord8 -> Right $ evalContT getWord8
    s -> Left $ "Expected Word8, but got " ++ show s

instance Serialise Word16 where
  schemaVia _ _ = SWord16
  toEncoding x = (2, BB.word16BE x)
  getDecoderVia _ = ReaderT $ \case
    SWord16 -> Right $ evalContT $ do
      a <- getWord8
      b <- getWord8
      return $! fromIntegral a `unsafeShiftL` 8 .|. fromIntegral b
    s -> Left $ "Expected Word16, but got " ++ show s

instance Serialise Word32 where
  schemaVia _ _ = SWord32
  toEncoding x = (4, BB.word32BE x)
  getDecoderVia _ = ReaderT $ \case
    SWord32 -> Right word32be
    s -> Left $ "Expected Word32, but got " ++ show s

instance Serialise Word64 where
  schemaVia _ _ = SWord64
  toEncoding x = (8, BB.word64BE x)
  getDecoderVia _ = ReaderT $ \case
    SWord64 -> Right word64be
    s -> Left $ "Expected Word64, but got " ++ show s

instance Serialise Word where
  schemaVia _ _ = SWord64
  toEncoding x = (8, BB.word64BE $ fromIntegral x)
  getDecoderVia _ = ReaderT $ \case
    SWord64 -> Right $ fromIntegral <$> word64be
    s -> Left $ "Expected Word64, but got " ++ show s

instance Serialise Int8 where
  schemaVia _ _ = SInt8
  toEncoding x = (1, BB.int8 x)
  getDecoderVia _ = ReaderT $ \case
    SInt8 -> Right $ fromIntegral <$> evalContT getWord8
    s -> Left $ "Expected Int8, but got " ++ show s

instance Serialise Int16 where
  schemaVia _ _ = SInt16
  toEncoding x = (2, BB.int16BE x)
  getDecoderVia _ = ReaderT $ \case
    SInt16 -> Right $ fromIntegral <$> word16be
    s -> Left $ "Expected Int16, but got " ++ show s

instance Serialise Int32 where
  schemaVia _ _ = SInt32
  toEncoding x = (4, BB.int32BE x)
  getDecoderVia _ = ReaderT $ \case
    SInt32 -> Right $ fromIntegral <$> word32be
    s -> Left $ "Expected Int32, but got " ++ show s

instance Serialise Int64 where
  schemaVia _ _ = SInt64
  toEncoding x = (8, BB.int64BE x)
  getDecoderVia _ = ReaderT $ \case
    SInt64 -> Right $ fromIntegral <$> word64be
    s -> Left $ "Expected Int64, but got " ++ show s

instance Serialise Int where
  schemaVia _ _ = SInt64
  toEncoding x = (8, BB.int64BE $ fromIntegral x)
  getDecoderVia _ = ReaderT $ \case
    SInt64 -> Right $ fromIntegral <$> word64be
    s -> Left $ "Expected Int64, but got " ++ show s

instance Serialise Float where
  schemaVia _ _ = SFloat
  toEncoding x = (4, BB.word32BE $ unsafeCoerce x)
  getDecoderVia _ = ReaderT $ \case
    SFloat -> Right $ unsafeCoerce <$> word32be
    s -> Left $ "Expected Float, but got " ++ show s

instance Serialise Double where
  schemaVia _ _ = SDouble
  toEncoding x = (8, BB.word64BE $ unsafeCoerce x)
  getDecoderVia _ = ReaderT $ \case
    SDouble -> Right $ unsafeCoerce <$> word64be
    s -> Left $ "Expected Double, but got " ++ show s

instance Serialise T.Text where
  schemaVia _ _ = SText
  toEncoding = toEncoding . T.encodeUtf8
  getDecoderVia _ = ReaderT $ \case
    SText -> Right $ T.decodeUtf8 <$> getBytes
    s -> Left $ "Expected Text, but got " ++ show s

instance Serialise Integer where
  schemaVia _ _ = SInteger
  toEncoding = encodeVarInt
  getDecoderVia _ = ReaderT $ \case
    SInteger -> Right $ evalContT decodeVarInt
    s -> Left $ "Expected Integer, but got " ++ show s

instance Serialise a => Serialise (Maybe a) where
  schemaVia _ = substSchema (Proxy :: Proxy (Either () a))
  toEncoding = toEncoding . maybe (Left ()) Right
  getDecoderVia ss = fmap (either (\() -> Nothing) Just) <$> getDecoderVia ss

word16be :: B.ByteString -> Word16
word16be = \s ->
  (fromIntegral (s `B.unsafeIndex` 0) `unsafeShiftL` 8) .|.
  (fromIntegral (s `B.unsafeIndex` 1))

word32be :: B.ByteString -> Word32
word32be = \s ->
  (fromIntegral (s `B.unsafeIndex` 0) `unsafeShiftL` 24) .|.
  (fromIntegral (s `B.unsafeIndex` 1) `unsafeShiftL` 16) .|.
  (fromIntegral (s `B.unsafeIndex` 2) `unsafeShiftL`  8) .|.
  (fromIntegral (s `B.unsafeIndex` 3) )

word64be :: B.ByteString -> Word64
word64be = \s ->
  (fromIntegral (s `B.unsafeIndex` 0) `unsafeShiftL` 56) .|.
  (fromIntegral (s `B.unsafeIndex` 1) `unsafeShiftL` 48) .|.
  (fromIntegral (s `B.unsafeIndex` 2) `unsafeShiftL` 40) .|.
  (fromIntegral (s `B.unsafeIndex` 3) `unsafeShiftL` 32) .|.
  (fromIntegral (s `B.unsafeIndex` 4) `unsafeShiftL` 24) .|.
  (fromIntegral (s `B.unsafeIndex` 5) `unsafeShiftL` 16) .|.
  (fromIntegral (s `B.unsafeIndex` 6) `unsafeShiftL`  8) .|.
  (fromIntegral (s `B.unsafeIndex` 7) )

instance Serialise B.ByteString where
  schemaVia _ _ = SBytes
  toEncoding bs = encodeVarInt (B.length bs)
    <> (Sum $ B.length bs, BB.byteString bs)
  getDecoderVia _ = ReaderT $ \case
    SBytes -> Right getBytes
    s -> Left $ "Expected SBytes, but got " ++ show s

instance Serialise a => Serialise [a] where
  schemaVia _ ts = SList (substSchema (Proxy :: Proxy a) ts)
  toEncoding xs = encodeVarInt (length xs)
    <> encodeMulti (map toEncoding xs)
  getDecoderVia ss = ReaderT $ \case
    SList s -> do
      getItem <- runReaderT (getDecoderVia ss) s
      return $ evalContT $ do
        n <- decodeVarInt
        offsets <- replicateM n decodeVarInt
        asks $ \bs -> [decodeAt ofs getItem bs | ofs <- take n $ 0 : offsets]
    s -> Left $ "Expected Schema, but got " ++ show s

instance Serialise a => Serialise (Identity a) where
  schemaVia _ ts = schemaVia (Proxy :: Proxy a) ts
  toEncoding = toEncoding . runIdentity
  getDecoderVia ss = fmap Identity <$> getDecoderVia ss

extractFieldWith :: Plan (Decoder a) -> T.Text -> Plan (Decoder a)
extractFieldWith g name = ReaderT $ \case
  SRecord schs -> do
    let schs' = [(k, (i, s)) | (i, (k, s)) <- zip [0..] schs]
    case lookup name schs' of
      Just (i, sch) -> do
        m <- runReaderT g sch
        return $ evalContT $ do
          offsets <- (0:) <$> mapM (const decodeVarInt) schs
          lift $ \bs -> m $ B.drop (offsets !! i) bs
      Nothing -> Left $ "Schema not found for " ++ T.unpack name
  s -> Left $ "Expected Record, but got " ++ show s

instance (Serialise a, Serialise b) => Serialise (a, b) where
  schemaVia _ ts = SProduct [substSchema (Proxy :: Proxy a) ts, substSchema (Proxy :: Proxy b) ts]
  toEncoding (a, b) = encodeMulti [toEncoding a, toEncoding b]
  getDecoderVia ss = decodePair (,) (getDecoderVia ss) (getDecoderVia ss)

decodePair :: (a -> b -> c)
  -> Plan (Decoder a)
  -> Plan (Decoder b)
  -> Plan (Decoder c)
decodePair f extA extB = ReaderT $ \case
  SProduct [sa, sb] -> do
    getA <- runReaderT extA sa
    getB <- runReaderT extB sb
    return $ evalContT $ do
      offA <- decodeVarInt
      offB <- decodeVarInt
      asks $ \bs -> getA bs `f` decodeAt (offA `asTypeOf ` offB) getB bs
  s -> Left $ "Expected Product [a, b], but got " ++ show s

instance (Serialise a, Serialise b) => Serialise (Either a b) where
  schemaVia _ ts = SSum [substSchema (Proxy :: Proxy a) ts, substSchema (Proxy :: Proxy b) ts]
  toEncoding (Left a) = (1, BB.word8 0) <> toEncoding a
  toEncoding (Right b) = (1, BB.word8 1) <> toEncoding b
  getDecoderVia ss = ReaderT $ \case
    SSum [sa, sb] -> do
      getA <- runReaderT (getDecoderVia ss) sa
      getB <- runReaderT (getDecoderVia ss) sb
      return $ evalContT $ do
        t <- decodeVarInt
        case t :: Word8 of
          0 -> Left <$> lift getA
          _ -> Right <$> lift getB
    s -> Left $ "Expected Sum [a, b], but got " ++ show s

encodeMulti :: [Encoding] -> Encoding
encodeMulti ls = foldMap encodeVarInt offsets <> foldMap id ls where
  offsets = drop 1 $ scanl (+) 0 $ map (getSum . fst) ls

data RecordDecoder i x = Done x | forall a. More !i !(Plan (Decoder a)) (RecordDecoder i (Decoder a -> x))

deriving instance Functor (RecordDecoder i)

instance Applicative (RecordDecoder i) where
  pure = Done
  Done f <*> a = fmap f a
  More i p k <*> c = More i p (flip <$> k <*> c)

gschemaViaRecord :: forall proxy a. (GSerialiseRecord (Rep a), Generic a, Typeable a) => proxy a -> [TypeRep] -> Schema
gschemaViaRecord p ts = SFix $ SRecord $ recordSchema (Proxy :: Proxy (Rep a)) (typeRep p : ts)

gtoEncodingRecord :: (GSerialiseRecord (Rep a), Generic a) => a -> Encoding
gtoEncodingRecord = encodeMulti . recordEncoder . from

ggetDecoderViaRecord :: (GSerialiseRecord (Rep a), Generic a, Typeable a) => [Decoder Dynamic] -> Plan (Decoder a)
ggetDecoderViaRecord decs = ReaderT $ \case
  SRecord schs -> do
    let schs' = [(k, (i, s)) | (i, (k, s)) <- zip [0..] schs]
    let go :: RecordDecoder T.Text x -> Either String ([Int] -> x)
        go (Done a) = Right $ const a
        go (More name p k) = case lookup name schs' of
          Nothing -> Left $ "Schema not found for " ++ T.unpack name
          Just (i, sch) -> do
            getItem <- runReaderT p sch
            r <- go k
            return $ \offsets -> r offsets (decodeAt (offsets !! i) getItem)
    m <- go (recordDecoder decs)
    return $ evalContT $ do
      offsets <- (0:) <$> mapM (const decodeVarInt) schs
      asks $ \bs -> to $ m offsets bs
  SSelf i -> return $ fmap (`fromDyn` error "Invalid recursion") $ decs !! fromIntegral i
  SFix s -> mfix $ \a -> runReaderT (ggetDecoderViaRecord (fmap toDyn a : decs)) s
  s -> Left $ "Expected Record, but got " ++ show s

class GSerialiseRecord f where
  recordSchema :: proxy f -> [TypeRep] -> [(T.Text, Schema)]
  recordEncoder :: f x -> [Encoding]
  recordDecoder :: [Decoder Dynamic] -> RecordDecoder T.Text (Decoder (f x))

instance (Serialise a, Selector c, GSerialiseRecord r) => GSerialiseRecord (S1 c (K1 i a) :*: r) where
  recordSchema _ ts = (T.pack $ selName (M1 undefined :: M1 i c (K1 i a) x), substSchema (Proxy :: Proxy a) ts)
    : recordSchema (Proxy :: Proxy r) ts
  recordEncoder (M1 (K1 a) :*: r) = toEncoding a : recordEncoder r
  recordDecoder ss = More (T.pack $ selName (M1 undefined :: M1 i c (K1 i a) x)) (getDecoderVia ss)
    $ fmap (\r a -> (:*:) <$> fmap (M1 . K1) a <*> r) (recordDecoder ss)

instance (Serialise a, Selector c) => GSerialiseRecord (S1 c (K1 i a)) where
  recordSchema _ ts = [(T.pack $ selName (M1 undefined :: M1 i c (K1 i a) x), substSchema (Proxy :: Proxy a) ts)]
  recordEncoder (M1 (K1 a)) = [toEncoding a]
  recordDecoder ss = More (T.pack $ selName (M1 undefined :: M1 i c (K1 i a) x)) (getDecoderVia ss)
    $ Done $ fmap $ M1 . K1

instance (GSerialiseRecord f) => GSerialiseRecord (C1 c f) where
  recordSchema _ = recordSchema (Proxy :: Proxy f)
  recordEncoder (M1 a) = recordEncoder a
  recordDecoder ss = fmap M1 <$> recordDecoder ss

instance (GSerialiseRecord f) => GSerialiseRecord (D1 c f) where
  recordSchema _ = recordSchema (Proxy :: Proxy f)
  recordEncoder (M1 a) = recordEncoder a
  recordDecoder ss = fmap M1 <$> recordDecoder ss

class GSerialiseProduct f where
  productSchema :: proxy f -> [TypeRep] -> [Schema]
  productEncoder :: f x -> [Encoding]
  productDecoder :: [Decoder Dynamic] -> RecordDecoder () (Decoder (f x))

instance GSerialiseProduct U1 where
  productSchema _ _ = []
  productEncoder _ = []
  productDecoder _ = Done (pure U1)

instance (Serialise a) => GSerialiseProduct (K1 i a) where
  productSchema _ ts = [substSchema (Proxy :: Proxy a) ts]
  productEncoder (K1 a) = [toEncoding a]
  productDecoder ss = More () (getDecoderVia ss) $ Done $ fmap K1

instance GSerialiseProduct f => GSerialiseProduct (M1 i c f) where
  productSchema _ ts = productSchema (Proxy :: Proxy f) ts
  productEncoder (M1 a) = productEncoder a
  productDecoder ss = fmap M1 <$> productDecoder ss

instance (GSerialiseProduct f, GSerialiseProduct g) => GSerialiseProduct (f :*: g) where
  productSchema _ ts = productSchema (Proxy :: Proxy f) ts ++ productSchema (Proxy :: Proxy g) ts
  productEncoder (f :*: g) = productEncoder f ++ productEncoder g
  productDecoder ss = liftA2 (:*:) <$> productDecoder ss <*> productDecoder ss

getDecoderViaProduct' :: GSerialiseProduct f => [Decoder Dynamic] -> [Schema] -> Either String (Decoder (f x))
getDecoderViaProduct' recs schs0 = do
  let go :: Int -> [Schema] -> RecordDecoder () x -> Either String ([Int] -> x)
      go _ _ (Done a) = Right $ const a
      go _ [] _ = Left "Mismatching number of fields"
      go i (sch : schs) (More () p k) = do
        getItem <- runReaderT p sch
        r <- go (i + 1) schs k
        return $ \offsets -> r offsets (decodeAt (offsets !! i) getItem)
  m <- go 0 schs0 (productDecoder recs)
  return $ evalContT $ do
    offsets <- (0:) <$> mapM (const decodeVarInt) schs0
    asks $ \bs -> m offsets bs

gschemaViaVariant :: forall proxy a. (GSerialiseVariant (Rep a), Typeable a, Generic a) => proxy a -> [TypeRep] -> Schema
gschemaViaVariant p ts = SFix $ SVariant $ variantSchema (Proxy :: Proxy (Rep a)) (typeRep p : ts)

gtoEncodingVariant :: (GSerialiseVariant (Rep a), Generic a) => a -> Encoding
gtoEncodingVariant = variantEncoder 0 . from

ggetDecoderViaVariant :: (GSerialiseVariant (Rep a), Generic a, Typeable a) => [Decoder Dynamic] -> Plan (Decoder a)
ggetDecoderViaVariant decs = ReaderT $ \case
  SVariant schs0 -> do
    let ds = variantDecoder decs
    ds' <- sequence
      [ case lookup name ds of
          Nothing -> Left $ "Schema not found for " ++ T.unpack name
          Just f -> f sch
      | (name, sch) <- schs0]
    return $ evalContT $ do
      i <- decodeVarInt
      lift $ fmap to $ ds' !! i
  SSelf i -> return $ fmap (`fromDyn`error "Invalid recursion") $ decs !! fromIntegral i
  SFix s -> mfix $ \a -> runReaderT (ggetDecoderViaVariant (fmap toDyn a : decs)) s
  s -> Left $ "Expected Variant, but got " ++ show s

class GSerialiseVariant f where
  variantCount :: proxy f -> Int
  variantSchema :: proxy f -> [TypeRep] -> [(T.Text, [Schema])]
  variantEncoder :: Int -> f x -> Encoding
  variantDecoder :: [Decoder Dynamic] -> [(T.Text, [Schema] -> Either String (Decoder (f x)))]

instance (GSerialiseVariant f, GSerialiseVariant g) => GSerialiseVariant (f :+: g) where
  variantCount _ = variantCount (Proxy :: Proxy f) + variantCount (Proxy :: Proxy g)
  variantSchema _ ts = variantSchema (Proxy :: Proxy f) ts ++ variantSchema (Proxy :: Proxy g) ts
  variantEncoder i (L1 f) = variantEncoder i f
  variantEncoder i (R1 g) = variantEncoder (i + variantCount (Proxy :: Proxy f)) g
  variantDecoder recs = fmap (fmap (fmap (fmap (fmap L1)))) (variantDecoder recs)
    ++ fmap (fmap (fmap (fmap (fmap R1)))) (variantDecoder recs)

instance (GSerialiseProduct f, Constructor c) => GSerialiseVariant (C1 c f) where
  variantCount _ = 1
  variantSchema _ ts = [(T.pack $ conName (M1 undefined :: M1 i c f x), productSchema (Proxy :: Proxy f) ts)]
  variantEncoder i (M1 a) = encodeVarInt i <> encodeMulti (productEncoder a)
  variantDecoder recs = [(T.pack $ conName (M1 undefined :: M1 i c f x), fmap (fmap (fmap M1)) $ getDecoderViaProduct' recs) ]

instance (GSerialiseVariant f) => GSerialiseVariant (S1 c f) where
  variantCount _ = variantCount (Proxy :: Proxy f)
  variantSchema _ ts = variantSchema (Proxy :: Proxy f) ts
  variantEncoder i (M1 a) = variantEncoder i a
  variantDecoder recs = fmap (fmap (fmap (fmap M1))) <$> variantDecoder recs

instance (GSerialiseVariant f) => GSerialiseVariant (D1 c f) where
  variantCount _ = variantCount (Proxy :: Proxy f)
  variantSchema _ ts = variantSchema (Proxy :: Proxy f) ts
  variantEncoder i (M1 a) = variantEncoder i a
  variantDecoder recs = fmap (fmap (fmap (fmap M1))) <$> variantDecoder recs
