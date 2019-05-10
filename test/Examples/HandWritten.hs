{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}

module Examples.HandWritten where

import           Data.Int
import           Data.Text                     ( Text )
import           Data.Word

import           FlatBuffers.FileIdentifier    ( HasFileIdentifier(..), unsafeFileIdentifier )
import           FlatBuffers.Internal.Positive ( Positive(getPositive) )
import           FlatBuffers.Read
import           FlatBuffers.Write


----------------------------------
---------- Primitives ------------
----------------------------------
data Primitives

instance HasFileIdentifier Primitives where
  getFileIdentifier = unsafeFileIdentifier "PRIM"

primitives ::
     Maybe Word8
  -> Maybe Word16
  -> Maybe Word32
  -> Maybe Word64
  -> Maybe Int8
  -> Maybe Int16
  -> Maybe Int32
  -> Maybe Int64
  -> Maybe Float
  -> Maybe Double
  -> Maybe Bool
  -> Maybe Text
  -> WriteTable Primitives
primitives a b c d e f g h i j k l =
  writeTable
    [ (optionalDef 1 . inline) word8    a
    , (optionalDef 1 . inline) word16   b
    , (optionalDef 1 . inline) word32   c
    , (optionalDef 1 . inline) word64   d
    , (optionalDef 1 . inline) int8     e
    , (optionalDef 1 . inline) int16    f
    , (optionalDef 1 . inline) int32    g
    , (optionalDef 1 . inline) int64    h
    , (optionalDef 1 . inline) float    i
    , (optionalDef 1 . inline) double   j
    , (optionalDef False . inline) bool k
    , optional text                     l
    ]

getPrimitives'a :: ReadCtx m => Table Primitives -> m Word8
getPrimitives'b :: ReadCtx m => Table Primitives -> m Word16
getPrimitives'c :: ReadCtx m => Table Primitives -> m Word32
getPrimitives'd :: ReadCtx m => Table Primitives -> m Word64
getPrimitives'e :: ReadCtx m => Table Primitives -> m Int8
getPrimitives'f :: ReadCtx m => Table Primitives -> m Int16
getPrimitives'g :: ReadCtx m => Table Primitives -> m Int32
getPrimitives'h :: ReadCtx m => Table Primitives -> m Int64
getPrimitives'i :: ReadCtx m => Table Primitives -> m Float
getPrimitives'j :: ReadCtx m => Table Primitives -> m Double
getPrimitives'k :: ReadCtx m => Table Primitives -> m Bool
getPrimitives'l :: ReadCtx m => Table Primitives -> m (Maybe Text)
getPrimitives'a = readTableFieldWithDef readWord8   0 1
getPrimitives'b = readTableFieldWithDef readWord16  1 1
getPrimitives'c = readTableFieldWithDef readWord32  2 1
getPrimitives'd = readTableFieldWithDef readWord64  3 1
getPrimitives'e = readTableFieldWithDef readInt8    4 1
getPrimitives'f = readTableFieldWithDef readInt16   5 1
getPrimitives'g = readTableFieldWithDef readInt32   6 1
getPrimitives'h = readTableFieldWithDef readInt64   7 1
getPrimitives'i = readTableFieldWithDef readFloat   8 1
getPrimitives'j = readTableFieldWithDef readDouble  9 1
getPrimitives'k = readTableFieldWithDef readBool    10 False
getPrimitives'l = readTableFieldOpt     readText    11

----------------------------------
------------- Color --------------
----------------------------------
data Color
  = ColorRed
  | ColorGreen
  | ColorBlue
  | ColorGray
  | ColorBlack
  deriving (Eq, Show, Read, Ord, Bounded)

{-# INLINE toColor #-}
toColor :: Word16 -> Maybe Color
toColor n =
  case n of
    0 -> Just ColorRed
    1 -> Just ColorGreen
    2 -> Just ColorBlue
    5 -> Just ColorGray
    8 -> Just ColorBlack
    _ -> Nothing

{-# INLINE fromColor #-}
fromColor :: Color -> Word16
fromColor n =
  case n of
    ColorRed   -> 0
    ColorGreen -> 1
    ColorBlue  -> 2
    ColorGray  -> 5
    ColorBlack -> 8

----------------------------------
------------- Enums --------------
----------------------------------
data Enums

enums :: Maybe Word16 -> Maybe (WriteStruct StructWithEnum) -> [Word16] -> Maybe [WriteStruct StructWithEnum] -> WriteTable Enums
enums x1 x2 x3 x4 = writeTable
  [ (optionalDef 2 . inline) word16 x1
  , optional unWriteStruct x2
  , (writeVector . inline) word16 x3
  , (optional . writeVector) unWriteStruct x4
  ]

getEnums'x :: ReadCtx m => Table Enums -> m Word16
getEnums'x = readTableFieldWithDef readWord16 0 2

getEnums'y :: ReadCtx m => Table Enums -> m (Maybe (Struct StructWithEnum))
getEnums'y = readTableFieldOpt readStruct' 1

getEnums'xs :: ReadCtx m => Table Enums -> m (Vector Word16)
getEnums'xs = readTableFieldReq (readPrimVector Word16Vec) 2 "xs"

getEnums'ys :: ReadCtx m => Table Enums -> m (Maybe (Vector (Struct StructWithEnum)))
getEnums'ys = readTableFieldOpt (readStructVector 6) 3



data StructWithEnum

structWithEnum :: Int8 -> Word16 -> Int8 -> WriteStruct StructWithEnum
structWithEnum x1 x2 x3 = writeStruct 2
  [ padded 1 (int8 x3)
  , word16 x2
  , padded 1 (int8 x1)
  ]

getStructWithEnum'x :: ReadCtx m => Struct StructWithEnum -> m Int8
getStructWithEnum'x = readStructField readInt8 0

getStructWithEnum'y :: ReadCtx m => Struct StructWithEnum -> m Word16
getStructWithEnum'y = readStructField readWord16 2

getStructWithEnum'z :: ReadCtx m => Struct StructWithEnum -> m Int8
getStructWithEnum'z = readStructField readInt8 4

----------------------------------
------------- Structs ------------
----------------------------------
data Struct1

struct1 :: Word8 -> Int8 -> Int8 -> WriteStruct Struct1
struct1 a b c =
  writeStruct 1
    [ int8 c
    , int8 b
    , word8 a
    ]

getStruct1'x :: ReadCtx m => Struct Struct1 -> m Word8
getStruct1'x = readStructField readWord8 0

getStruct1'y :: ReadCtx m => Struct Struct1 -> m Int8
getStruct1'y = readStructField readInt8 1

getStruct1'z :: ReadCtx m => Struct Struct1 -> m Int8
getStruct1'z = readStructField readInt8 2


data Struct2

struct2 :: Int16 -> WriteStruct Struct2
struct2 a = writeStruct 4
  [ padded 2 (int16 a)
  ]

getStruct2'x :: ReadCtx m => Struct Struct2 -> m Int16
getStruct2'x = readStructField readInt16 0


data Struct3

struct3 :: Int16 -> Word64 -> Word8 -> WriteStruct Struct3
struct3 a b c = writeStruct 8
  [ padded 7 (word8 c)
  , word64 b
  , padded 6 (int16 a)
  ]

getStruct3'x :: Struct Struct3 -> Struct Struct2
getStruct3'x = readStructField readStruct 0

getStruct3'y :: ReadCtx m => Struct Struct3 -> m Word64
getStruct3'y = readStructField readWord64 8

getStruct3'z :: ReadCtx m => Struct Struct3 -> m Word8
getStruct3'z = readStructField readWord8 16


data Struct4

struct4 :: Int16 -> Int8 -> Int64 -> Bool -> WriteStruct Struct4
struct4 a b c d = writeStruct 8
  [ padded 7 (bool d)
  , int64 c
  , padded 3 (int8 b)
  , padded 2 (int16 a)
  ]

getStruct4'w :: Struct Struct4 -> Struct Struct2
getStruct4'w = readStructField readStruct 0

getStruct4'x :: ReadCtx m => Struct Struct4 -> m Int8
getStruct4'x = readStructField readInt8 4

getStruct4'y :: ReadCtx m => Struct Struct4 -> m Int64
getStruct4'y = readStructField readInt64 8

getStruct4'z :: ReadCtx m => Struct Struct4 -> m Bool
getStruct4'z = readStructField readBool 16


data Structs

structs ::
     Maybe (WriteStruct Struct1)
  -> Maybe (WriteStruct Struct2)
  -> Maybe (WriteStruct Struct3)
  -> Maybe (WriteStruct Struct4)
  -> WriteTable Structs
structs x1 x2 x3 x4 = writeTable
  [ optional unWriteStruct x1
  , optional unWriteStruct x2
  , optional unWriteStruct x3
  , optional unWriteStruct x4
  ]

getStructs'a :: ReadCtx m => Table Structs -> m (Maybe (Struct Struct1))
getStructs'a = readTableFieldOpt readStruct' 0

getStructs'b :: ReadCtx m => Table Structs -> m (Maybe (Struct Struct2))
getStructs'b = readTableFieldOpt readStruct' 1

getStructs'c :: ReadCtx m => Table Structs -> m (Maybe (Struct Struct3))
getStructs'c = readTableFieldOpt readStruct' 2

getStructs'd :: ReadCtx m => Table Structs -> m (Maybe (Struct Struct4))
getStructs'd = readTableFieldOpt readStruct' 3


----------------------------------
------------- Sword -------------
----------------------------------
data Sword

sword :: Maybe Text -> WriteTable Sword
sword x1 = writeTable [optional text x1]

getSword'x :: ReadCtx m => Table Sword -> m (Maybe Text)
getSword'x = readTableFieldOpt readText 0

----------------------------------
------------- Axe -------------
----------------------------------
data Axe

axe :: Maybe Int32 -> WriteTable Axe
axe x1 = writeTable [(optionalDef 0 . inline) int32 x1]

getAxe'y :: ReadCtx m => Table Axe -> m Int32
getAxe'y = readTableFieldWithDef readInt32 0 0
----------------------------------
------------- Weapon --------------
----------------------------------
data Weapon
  = Weapon'Sword !(Table Sword)
  | Weapon'Axe !(Table Axe)

class EncodeWeapon a where
  weapon :: WriteTable a -> WriteUnion Weapon

instance EncodeWeapon Sword where
  weapon = writeUnion 1

instance EncodeWeapon Axe where
  weapon = writeUnion 2

readWeapon :: ReadCtx m => Positive Word8 -> PositionInfo -> m (Union Weapon)
readWeapon n pos =
  case getPositive n of
    1  -> Union . Weapon'Sword <$> readTable pos
    2  -> Union . Weapon'Axe <$> readTable pos
    n' -> pure $ UnionUnknown n'

----------------------------------
------- TableWithUnion -----------
----------------------------------
data TableWithUnion

tableWithUnion :: Maybe (WriteUnion Weapon) -> WriteTable TableWithUnion
tableWithUnion x1 = writeTable
  [ optional writeUnionType x1
  , optional writeUnionValue x1
  ]

getTableWithUnion'uni :: ReadCtx m => Table TableWithUnion -> m (Union Weapon)
getTableWithUnion'uni = readTableFieldUnion readWeapon 0

----------------------------------
------------ Vectors -------------
----------------------------------
data Vectors

vectors ::
     Maybe [Word8]
  -> Maybe [Word16]
  -> Maybe [Word32]
  -> Maybe [Word64]
  -> Maybe [Int8]
  -> Maybe [Int16]
  -> Maybe [Int32]
  -> Maybe [Int64]
  -> Maybe [Float]
  -> Maybe [Double]
  -> Maybe [Bool]
  -> Maybe [Text]
  -> WriteTable Vectors
vectors a b c d e f g h i j k l =
  writeTable
    [ (optional . writeVector . inline) word8    a
    , (optional . writeVector . inline) word16   b
    , (optional . writeVector . inline) word32   c
    , (optional . writeVector . inline) word64   d
    , (optional . writeVector . inline) int8     e
    , (optional . writeVector . inline) int16    f
    , (optional . writeVector . inline) int32    g
    , (optional . writeVector . inline) int64    h
    , (optional . writeVector . inline) float    i
    , (optional . writeVector . inline) double   j
    , (optional . writeVector . inline) bool     k
    , (optional . writeVector)          text     l
    ]

getVectors'a :: ReadCtx m => Table Vectors -> m (Maybe (Vector Word8))
getVectors'b :: ReadCtx m => Table Vectors -> m (Maybe (Vector Word16))
getVectors'c :: ReadCtx m => Table Vectors -> m (Maybe (Vector Word32))
getVectors'd :: ReadCtx m => Table Vectors -> m (Maybe (Vector Word64))
getVectors'e :: ReadCtx m => Table Vectors -> m (Maybe (Vector Int8))
getVectors'f :: ReadCtx m => Table Vectors -> m (Maybe (Vector Int16))
getVectors'g :: ReadCtx m => Table Vectors -> m (Maybe (Vector Int32))
getVectors'h :: ReadCtx m => Table Vectors -> m (Maybe (Vector Int64))
getVectors'i :: ReadCtx m => Table Vectors -> m (Maybe (Vector Float))
getVectors'j :: ReadCtx m => Table Vectors -> m (Maybe (Vector Double))
getVectors'k :: ReadCtx m => Table Vectors -> m (Maybe (Vector Bool))
getVectors'l :: ReadCtx m => Table Vectors -> m (Maybe (Vector Text))
getVectors'a = readTableFieldOpt (readPrimVector Word8Vec)   0
getVectors'b = readTableFieldOpt (readPrimVector Word16Vec)  1
getVectors'c = readTableFieldOpt (readPrimVector Word32Vec)  2
getVectors'd = readTableFieldOpt (readPrimVector Word64Vec)  3
getVectors'e = readTableFieldOpt (readPrimVector Int8Vec)    4
getVectors'f = readTableFieldOpt (readPrimVector Int16Vec)   5
getVectors'g = readTableFieldOpt (readPrimVector Int32Vec)   6
getVectors'h = readTableFieldOpt (readPrimVector Int64Vec)   7
getVectors'i = readTableFieldOpt (readPrimVector FloatVec)   8
getVectors'j = readTableFieldOpt (readPrimVector DoubleVec)  9
getVectors'k = readTableFieldOpt (readPrimVector BoolVec)    10
getVectors'l = readTableFieldOpt (readPrimVector TextVec)    11

----------------------------------
-------- VectorOfTables ----------
----------------------------------
data VectorOfTables

vectorOfTables :: Maybe [WriteTable Axe] -> WriteTable VectorOfTables
vectorOfTables x1 = writeTable
  [ (optional . writeVector) unWriteTable x1
  ]

getVectorOfTables'xs :: ReadCtx m => Table VectorOfTables -> m (Maybe (Vector (Table Axe)))
getVectorOfTables'xs = readTableFieldOpt readTableVector 0

----------------------------------
------- VectorOfStructs ----------
----------------------------------
data VectorOfStructs

vectorOfStructs ::
     Maybe [WriteStruct Struct1]
  -> Maybe [WriteStruct Struct2]
  -> Maybe [WriteStruct Struct3]
  -> Maybe [WriteStruct Struct4]
  -> WriteTable VectorOfStructs
vectorOfStructs x1 x2 x3 x4 = writeTable
  [ (optional . writeVector) unWriteStruct x1
  , (optional . writeVector) unWriteStruct x2
  , (optional . writeVector) unWriteStruct x3
  , (optional . writeVector) unWriteStruct x4
  ]

getVectorOfStructs'as :: ReadCtx m => Table VectorOfStructs -> m (Maybe (Vector (Struct Struct1)))
getVectorOfStructs'as = readTableFieldOpt (readStructVector 3) 0

getVectorOfStructs'bs :: ReadCtx m => Table VectorOfStructs -> m (Maybe (Vector (Struct Struct2)))
getVectorOfStructs'bs = readTableFieldOpt (readStructVector 4) 1

getVectorOfStructs'cs :: ReadCtx m => Table VectorOfStructs -> m (Maybe (Vector (Struct Struct3)))
getVectorOfStructs'cs = readTableFieldOpt (readStructVector 24) 2

getVectorOfStructs'ds :: ReadCtx m => Table VectorOfStructs -> m (Maybe (Vector (Struct Struct4)))
getVectorOfStructs'ds = readTableFieldOpt (readStructVector 24) 3


----------------------------------
------- VectorOfUnions -----------
----------------------------------
data VectorOfUnions

vectorOfUnions :: Maybe [WriteUnion Weapon] -> [WriteUnion Weapon] -> WriteTable VectorOfUnions
vectorOfUnions x1 x2 = writeTable
  [ x1t
  , x1v
  , x2t
  , x2v
  ]
  where
    (x1t, x1v) = writeUnionVectorOpt x1
    (x2t, x2v) = writeUnionVectorReq x2

getVectorOfUnions'xs :: ReadCtx m => Table VectorOfUnions -> m (Maybe (Vector (Union Weapon)))
getVectorOfUnions'xs = readTableFieldUnionVectorOpt readWeapon 0

getVectorOfUnions'xsReq :: ReadCtx m => Table VectorOfUnions -> m (Vector (Union Weapon))
getVectorOfUnions'xsReq = readTableFieldUnionVectorReq readWeapon 2 "xsReq"
