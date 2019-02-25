{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module FlatBuffers.Compiler.ParseTree where

import           Data.List.NonEmpty (NonEmpty)
import           Data.String        (IsString)
import           Data.Text          (Text)

data Schema = Schema
  { includes            :: [Include]
  , typeDecls           :: [TypeDecl]
  , enumDecls           :: [EnumDecl]
  , unionDecls          :: [UnionDecl]
  , rootDecls           :: [RootDecl]
  , fileExtensionDecls  :: [FileExtensionDecl]
  , fileIdentifierDecls :: [FileIdentifierDecl]
  , attributeDecls      :: [AttributeDecl]
  } deriving (Show, Eq)

instance Semigroup Schema where
  Schema i1 t1 e1 u1 r1 fe1 fi1 a1 <> Schema i2 t2 e2 u2 r2 fe2 fi2 a2 =
    Schema
      (i1 <> i2)
      (t1 <> t2)
      (e1 <> e2)
      (u1 <> u2)
      (r1 <> r2)
      (fe1 <> fe2)
      (fi1 <> fi2)
      (a1 <> a2)

instance Monoid Schema where
  mempty = Schema [] [] [] [] [] [] [] []

newtype Ident = Ident
  { unIdent :: Text
  } deriving (Show, Eq, IsString)

newtype Include = Include
  { unInclude :: StringLiteral
  } deriving (Show, Eq, IsString)

newtype StringLiteral = StringLiteral
  { unStringLiteral :: Text
  } deriving (Show, Eq, IsString)

newtype IntLiteral = IntLiteral
  { unIntLiteral :: Integer
  } deriving (Show, Eq, Num, Enum, Ord, Real, Integral)

newtype NumberLiteral = NumberLiteral
  { unNumberLiteral :: String
  } deriving (Show, Eq, IsString)

data Literal
  = LiteralN NumberLiteral
  | LiteralS StringLiteral
  deriving (Show, Eq)

newtype Metadata = Metadata
  { unMetadata :: NonEmpty (Ident, Maybe Literal)
  } deriving (Show, Eq)

newtype Namespace = Namespace
  { unNamespace :: NonEmpty Ident
  } deriving (Show, Eq)

data TypeDecl = TypeDecl
  { typeDeclType :: TypeDeclType
  , typeIdent    :: Ident
  , typeMetadata :: Maybe Metadata
  , typeFields   :: NonEmpty Field
  } deriving (Show, Eq)

data TypeDeclType
  = Table
  | Struct
  deriving (Show, Eq)

data Field = Field
  { fieldIdent    :: Ident
  , fieldType     :: Type
  , fieldDefault  :: Maybe NumberLiteral
  , fieldMetadata :: Maybe Metadata
  } deriving (Show, Eq)

data EnumDecl = EnumDecl
  { enumDeclIdent    :: Ident
  , enumDeclType     :: Type
  , enumDeclMetadata :: Maybe Metadata
  , enumDeclVals     :: NonEmpty EnumValDecl
  } deriving (Show, Eq)

data EnumValDecl = EnumValDecl
  { enumValDeclIdent   :: Ident
  , enumValDeclLiteral :: Maybe IntLiteral
  } deriving (Show, Eq)

data UnionDecl = UnionDecl
  { unionDeclIdent    :: Ident
  , unionDeclMetadata :: Maybe Metadata
  , unionDeclVals     :: NonEmpty UnionValDecl
  } deriving (Show, Eq)

data UnionValDecl = UnionValDecl
  { unionValDeclAlias :: Maybe Ident
  , unionValDeclType  :: Ident
  } deriving (Show, Eq)

data Type
  -- numeric
  = Tint8
  | Tint16
  | Tint32
  | Tint64
  | Tword8
  | Tword16
  | Tword32
  | Tword64
  -- floating point
  | Tfloat
  | Tdouble
  -- others
  | Tbool
  | Tstring
  | Tvector Type
  | Tident Ident
  deriving (Show, Eq)

newtype RootDecl = RootDecl Ident
  deriving (Show, Eq, IsString)

newtype FileExtensionDecl = FileExtensionDecl StringLiteral
  deriving (Show, Eq, IsString)

newtype FileIdentifierDecl = FileIdentifierDecl StringLiteral
  deriving (Show, Eq, IsString)

newtype AttributeDecl = AttributeDecl Ident
  deriving (Show, Eq, IsString)