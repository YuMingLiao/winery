# winery

winery is a serialisation library for Haskell. It tries to achieve two
goals: compact representation and perpetual inspectability.

The standard `binary` library has no way to inspect the serialised value without the original instance.

There's `serialise`, which is an alternative library based on CBOR. Every value has to be accompanied with tags, so it tends to be redundant for arrays of small values. Encoding records with field names is also redudant.

## Interface

The interface is simple; `serialise` encodes a value with its schema, and
`deserialise` decodes a ByteString using the schema in it.

```haskell
class Serialise a

serialise :: Serialise a => a -> B.ByteString
deserialise :: Serialise a => B.ByteString -> Either String a
```

It's also possible to serialise schemata and data separately.

```haskell
-- Note that 'Schema' is an instance of 'Serialise'
schema :: Serialise a => proxy a -> Schema
serialiseOnly :: Serialise a => a -> B.ByteString
```

`getDecoder` gives you a deserialiser.

```haskell
getDecoder :: Serialise a => Schema -> Either StrategyError (ByteString -> a)
```

For user-defined datatypes, you can either define instances

```haskell
instance Serialise Foo where
  schemaVia = gschemaViaRecord
  toEncoding = gtoEncodingRecord
  deserialiser = gdeserialiserRecord Nothing
```

for single-constructor records, or just

```haskell
instance Serialise Foo
```

for any ADT. The former explicitly describes field names in the schema, and the
latter does constructor names.

## The schema

The definition of `Schema` is as follows:

```haskell
data Schema = SSchema !Word8
  | SUnit
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
  | SList !Schema
  | SArray !(VarInt Int) !Schema -- fixed size
  | SProduct [Schema]
  | SProductFixed [(VarInt Int, Schema)] -- fixed size
  | SRecord [(T.Text, Schema)]
  | SVariant [(T.Text, [Schema])]
  | SFix Schema -- ^ binds a fixpoint
  | SSelf !Word8 -- ^ @SSelf n@ refers to the n-th innermost fixpoint
  deriving (Show, Read, Eq, Generic)
```

The `Serialise` instance is derived by generics.

There are some special schemata:

* `SSchema n` is a schema of schema. The winery library stores the concrete schema of `Schema` for each version, so it can deserialise data even if the schema changes.
* `SFix` binds a fixpoint.
* `SSelf n` refers to the n-th innermost fixpoint bound by `SFix`. This allows it to provide schemata for inductive datatypes.

## Backward compatibility

If having default values for missing fields is sufficient, you can pass a
default value to `gdeserialiserRecord`:

```haskell
  deserialiser = gdeserialiserRecord $ Just $ Foo "" 42 0
```

You can also build a custom deserialiser using the Alternative instance and combinators such as `extractField`, `extractConstructor`, etc.

## Pretty-printing

`Term` can be deserialised from any winery data. It can be pretty-printed using the `Pretty` instance:

```
{ bar: "hello"
, baz: 3.141592653589793
, foo: Just 42
}
```

## Benchmark

```haskell
data TestRec = TestRec
  { id_ :: !Int
  , first_name :: !Text
  , last_name :: !Text
  , email :: !Text
  , gender :: !Gender
  , num :: !Int
  , latitude :: !Double
  , longitude :: !Double
  } deriving (Show, Generic)
```

(De)serialisation of the datatype above using generic instances:

```
serialise/winery                         mean 658.6 μs  ( +- 45.04 μs  )
serialise/binary                         mean 1.056 ms  ( +- 58.95 μs  )
serialise/serialise                      mean 258.8 μs  ( +- 5.654 μs  )
deserialise/winery                       mean 706.4 μs  ( +- 52.41 μs  )
deserialise/binary                       mean 1.393 ms  ( +- 56.71 μs  )
deserialise/serialise                    mean 765.8 μs  ( +- 30.26 μs  )
```

Not bad, considering that binary and serialise don't encode field names.
