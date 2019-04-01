{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds     #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

module FlatBuffers.Internal.Compiler.SemanticAnalysis where

import           Control.Monad                            (forM_, when, void)
import           Control.Monad.Except                     (MonadError,
                                                           throwError)
import           Control.Monad.Reader                     (MonadReader (..), runReaderT)
import           Control.Monad.State                      (MonadState, State, evalState,
                                                           evalStateT, get,
                                                           modify, put)
import           Data.Coerce                              (coerce)
import           Data.Foldable                            (find,
                                                           traverse_, foldlM, asum)
import           Data.Functor                             (($>), (<&>))
import           Data.Int
import           Data.Ix                                  (inRange)
import qualified Data.List                                as List
import           Data.List.NonEmpty                       (NonEmpty)
import qualified Data.List.NonEmpty                       as NE
import           Data.Map.Strict                          (Map)
import qualified Data.Map.Strict                          as Map
import           Data.Maybe                               (catMaybes, fromMaybe, isJust)
import           Data.Monoid                              (Sum (..))
import           Data.Scientific                          (Scientific)
import qualified Data.Scientific                          as Scientific
import           Data.Text                                (Text)
import qualified Data.Text                                as T
import           Data.Traversable                         (for)
import           Data.Word
import           FlatBuffers.Constants                    (InlineSize (..))
import           FlatBuffers.Internal.Compiler.SyntaxTree (Ident, Namespace,
                                                           Schema, qualify, HasIdent(..), TypeRef(..), FileTree(..))
import qualified FlatBuffers.Internal.Compiler.SyntaxTree as ST
import           FlatBuffers.Internal.Compiler.ValidSyntaxTree
import           FlatBuffers.Internal.Util                (Display (..),
                                                           isPowerOfTwo, roundUpToNearestMultipleOf)
import           Text.Read                                (readMaybe)

-- |  The identifier in the reader environment represents the validation context,
-- the thing being validated (e.g. a fully-qualified struct name, or a table field name).
type ValidationCtx m = (MonadError Text m, MonadReader Ident m)

data SymbolTable enum struct table union = SymbolTable
  { allEnums   :: [(Namespace, enum)]
  , allStructs :: [(Namespace, struct)]
  , allTables  :: [(Namespace, table)]
  , allUnions  :: [(Namespace, union)]
  }
  deriving (Eq, Show)

instance Semigroup (SymbolTable e s t u)  where
  SymbolTable e1 s1 t1 u1 <> SymbolTable e2 s2 t2 u2 =
    SymbolTable (e1 <> e2) (s1 <> s2) (t1 <> t2) (u1 <> u2)

instance Monoid (SymbolTable e s t u) where
  mempty = SymbolTable [] [] [] []

type Stage1     = SymbolTable ST.EnumDecl ST.StructDecl ST.TableDecl ST.UnionDecl
type Stage2     = SymbolTable    EnumDecl ST.StructDecl ST.TableDecl ST.UnionDecl
type Stage3     = SymbolTable    EnumDecl    StructDecl ST.TableDecl ST.UnionDecl
type Stage4     = SymbolTable    EnumDecl    StructDecl    TableDecl ST.UnionDecl
type ValidDecls = SymbolTable    EnumDecl    StructDecl    TableDecl    UnionDecl

-- | Takes a collection of schemas, and pairs each type declaration with its corresponding namespace
createSymbolTables :: FileTree Schema -> FileTree Stage1
createSymbolTables = fmap (pairDeclsWithNamespaces . ST.decls)
  where
    pairDeclsWithNamespaces :: [ST.Decl] -> Stage1
    pairDeclsWithNamespaces = snd . foldl go ("", mempty)

    go :: (Namespace, Stage1) -> ST.Decl -> (Namespace, Stage1)
    go (currentNamespace, decls) decl =
      case decl of
        ST.DeclN (ST.NamespaceDecl newNamespace) -> (newNamespace, decls)
        ST.DeclE enum   -> (currentNamespace, decls <> SymbolTable [(currentNamespace, enum)] [] [] [])
        ST.DeclS struct -> (currentNamespace, decls <> SymbolTable [] [(currentNamespace, struct)] [] [])
        ST.DeclT table  -> (currentNamespace, decls <> SymbolTable [] [] [(currentNamespace, table)] [])
        ST.DeclU union  -> (currentNamespace, decls <> SymbolTable [] [] [] [(currentNamespace, union)])
        _               -> (currentNamespace, decls)

validateDecls :: MonadError Text m => FileTree Stage1 -> m (FileTree ValidDecls)
validateDecls symbolTable =
  flip runReaderT "" $ 
    validateEnums symbolTable >>= validateStructs >>= validateTables >>= validateUnions

----------------------------------
--------- Symbol search ----------
----------------------------------
data Match enum struct table union
  = MatchE (Namespace, enum)
  | MatchS (Namespace, struct)
  | MatchT (Namespace, table)
  | MatchU (Namespace, union)
  | NoMatch (NonEmpty Namespace) -- ^ the list of namespaces in which the type reference was searched for

-- | Looks for a type reference in a set of type declarations.
-- If none is found, the list of namespaces in which the type reference was searched for is returned.
findDecl ::
     (HasIdent e, HasIdent s, HasIdent t, HasIdent u)
  => Namespace
  -> FileTree (SymbolTable e s t u)
  -> TypeRef
  -> Match e s t u
findDecl currentNamespace symbolTables (TypeRef refNamespace refIdent) =
  let parentNamespaces' = parentNamespaces currentNamespace
      results = do
        parentNamespace <- parentNamespaces'
        let candidateNamespace = parentNamespace <> refNamespace
        let searchSymbolTable symbolTable =
              asum
                [ MatchE <$> find (\(ns, e) -> ns == candidateNamespace && getIdent e == refIdent) (allEnums symbolTable)
                , MatchS <$> find (\(ns, e) -> ns == candidateNamespace && getIdent e == refIdent) (allStructs symbolTable)
                , MatchT <$> find (\(ns, e) -> ns == candidateNamespace && getIdent e == refIdent) (allTables symbolTable)
                , MatchU <$> find (\(ns, e) -> ns == candidateNamespace && getIdent e == refIdent) (allUnions symbolTable)
                ]
        pure $ asum $ fmap searchSymbolTable symbolTables
  in 
    case asum results of
      Just match -> match
      Nothing    -> NoMatch parentNamespaces'

-- | Returns a list of all the namespaces "between" the current namespace
-- and the root namespace, in that order.
-- See: https://github.com/google/flatbuffers/issues/5234#issuecomment-471680403
-- 
-- > parentNamespaces "A.B.C" == ["A.B.C", "A.B", "A", ""]
parentNamespaces :: ST.Namespace -> NonEmpty ST.Namespace
parentNamespaces (ST.Namespace ns) =
  coerce $ NE.reverse $ NE.inits ns

----------------------------------
------------- Enums --------------
----------------------------------
validateEnums :: forall m. ValidationCtx m => FileTree Stage1 -> m (FileTree Stage2)
validateEnums symbolTables =
  for symbolTables $ \symbolTable -> do
    let enums = allEnums symbolTable
    let validate (namespace, enum) = do
          validEnum <- validateEnum (namespace, enum)
          pure (namespace, validEnum)
    validEnums <- traverse validate enums
    pure symbolTable { allEnums = validEnums }

-- TODO: add support for `bit_flags` attribute
validateEnum :: forall m. ValidationCtx m => (Namespace, ST.EnumDecl) -> m EnumDecl
validateEnum (currentNamespace, enum) =
  local (\_ -> qualify currentNamespace (getIdent enum)) $
    checkBitFlags >> checkDuplicateFields >> validEnum
  where
    validEnum = do
      enumType <- validateEnumType (ST.enumType enum)
      let enumVals = flip evalState Nothing . traverse mapEnumVal $ ST.enumVals enum
      validateOrder enumVals
      traverse_ (validateBounds enumType) enumVals
      pure EnumDecl
        { enumIdent = getIdent enum
        , enumType = enumType
        , enumVals = enumVals
        }

    mapEnumVal :: ST.EnumVal -> State (Maybe Integer) EnumVal
    mapEnumVal enumVal = do
      thisInt <-
        case ST.enumValLiteral enumVal of
          Just (ST.IntLiteral thisInt) ->
            pure thisInt
          Nothing ->
            get <&> \case
              Just lastInt -> lastInt + 1
              Nothing      -> 0
      put (Just thisInt)
      pure (EnumVal (getIdent enumVal) thisInt)

    validateOrder :: NonEmpty EnumVal -> m ()
    validateOrder xs =
      if all (\(x, y) -> enumValInt x < enumValInt y) (NE.toList xs `zip` NE.tail xs)
        then pure ()
        else throwErrorMsg "enum values must be specified in ascending order"

    validateBounds :: EnumType -> EnumVal -> m ()
    validateBounds enumType enumVal =
      local (\context -> context <> "." <> getIdent enumVal) $
        case enumType of
          EInt8 -> validateBounds' @Int8 enumVal
          EInt16 -> validateBounds' @Int16 enumVal
          EInt32 -> validateBounds' @Int32 enumVal
          EInt64 -> validateBounds' @Int64 enumVal
          EWord8 -> validateBounds' @Word8 enumVal
          EWord16 -> validateBounds' @Word16 enumVal
          EWord32 -> validateBounds' @Word32 enumVal
          EWord64 -> validateBounds' @Word64 enumVal

    validateBounds' :: forall a. (Integral a, Bounded a, Show a) => EnumVal -> m ()
    validateBounds' e =
      if inRange (toInteger (minBound @a), toInteger (maxBound @a)) (enumValInt e)
        then pure ()
        else throwErrorMsg $
              "enum value does not fit ["
              <> T.pack (show (minBound @a))
              <> "; "
              <> T.pack (show (maxBound @a))
              <> "]"

    validateEnumType :: ST.Type -> m EnumType
    validateEnumType t =
      case t of
        ST.TInt8 -> pure EInt8
        ST.TInt16 -> pure EInt16
        ST.TInt32 -> pure EInt32
        ST.TInt64 -> pure EInt64
        ST.TWord8 -> pure EWord8
        ST.TWord16 -> pure EWord16
        ST.TWord32 -> pure EWord32
        ST.TWord64 -> pure EWord64
        _          -> throwErrorMsg "underlying enum type must be integral"

    checkDuplicateFields :: m ()
    checkDuplicateFields =
      checkDuplicateIdentifiers
        (ST.enumVals enum)

    checkBitFlags :: m ()
    checkBitFlags =
      when (hasAttribute "bit_flags" (ST.enumMetadata enum)) $
        throwErrorMsg "`bit_flags` are not supported yet"


----------------------------------
------------ Tables --------------
----------------------------------
validateTables :: ValidationCtx m => FileTree Stage3 -> m (FileTree Stage4)
validateTables symbolTables =
  for symbolTables $ \symbolTable -> do
    let tables = allTables symbolTable
    let validate (namespace, table) = do
          validTable <- validateTable symbolTables (namespace, table)
          pure (namespace, validTable)
    validTables <- traverse validate tables
    pure symbolTable { allTables = validTables }

validateTable :: forall m. ValidationCtx m => FileTree Stage3 -> (Namespace, ST.TableDecl) -> m TableDecl
validateTable symbolTables (currentNamespace, table) =
  local (\_ -> qualify currentNamespace (getIdent table)) $ do

    let fields = ST.tableFields table
    let fieldsMetadata = ST.tableFieldMetadata <$> fields
    
    checkDuplicateFields
    validFields <- traverse validateTableField fields
    sortedFields <- sortFields fieldsMetadata validFields

    pure TableDecl
      { tableIdent = getIdent table
      , tableFields = sortedFields
      }

  where
    checkDuplicateFields :: m ()
    checkDuplicateFields = checkDuplicateIdentifiers (ST.tableFields table)

    sortFields :: [ST.Metadata] -> [TableField] -> m [TableField]
    sortFields metadata fields = do
      ids <- catMaybes <$> traverse (findIntAttr "id") metadata
      if null ids
        then pure fields
        else do
          when (length ids /= length fields) $
            throwErrorMsg "either all fields or no fields must have an 'id' attribute"

          let fieldsWithIds = List.sortOn snd $ zip fields ids
          void $ foldlM checkFieldId (-1) fieldsWithIds
          pure (fst <$> fieldsWithIds)
          
    checkFieldId :: Integer -> (TableField, Integer) -> m Integer
    checkFieldId lastId (field, id) =
      local (\context -> context <> "." <> getIdent field) $ do
        case tableFieldType field of
          TUnion _ _ ->
            when (id /= lastId + 2) $
              throwErrorMsg "the id of an union field must be the last field's id + 2"
          TVector _ (VUnion _) ->
            when (id /= lastId + 2) $
              throwErrorMsg "the id of a vector of unions field must be the last field's id + 2"
          _ ->
            when (id /= lastId + 1) $
              throwErrorMsg $ "field ids must be consecutive from 0; id " <> display (lastId + 1) <> " is missing"
        pure id
            
          
    validateTableField :: ST.TableField -> m TableField
    validateTableField tf =
      local (\context -> context <> "." <> getIdent tf) $ do
        validFieldType <- validateTableFieldType (ST.tableFieldMetadata tf) (ST.tableFieldDefault tf) (ST.tableFieldType tf)
        pure TableField
          { tableFieldIdent = getIdent tf
          , tableFieldType = validFieldType
          , tableFieldDeprecated = hasAttribute "deprecated" (ST.tableFieldMetadata tf)
          }

    validateTableFieldType :: ST.Metadata -> Maybe ST.DefaultVal -> ST.Type -> m TableFieldType
    validateTableFieldType md dflt tableFieldType =
      case tableFieldType of
        ST.TInt8 -> checkNoRequired md >> validateDefaultValAsInt dflt <&> TInt8
        ST.TInt16 -> checkNoRequired md >> validateDefaultValAsInt dflt <&> TInt16
        ST.TInt32 -> checkNoRequired md >> validateDefaultValAsInt dflt <&> TInt32
        ST.TInt64 -> checkNoRequired md >> validateDefaultValAsInt dflt <&> TInt64
        ST.TWord8 -> checkNoRequired md >> validateDefaultValAsInt dflt <&> TWord8
        ST.TWord16 -> checkNoRequired md >> validateDefaultValAsInt dflt <&> TWord16
        ST.TWord32 -> checkNoRequired md >> validateDefaultValAsInt dflt <&> TWord32
        ST.TWord64 -> checkNoRequired md >> validateDefaultValAsInt dflt <&> TWord64
        ST.TFloat -> checkNoRequired md >> validateDefaultValAsScientific dflt <&> TFloat
        ST.TDouble -> checkNoRequired md >> validateDefaultValAsScientific dflt <&> TDouble
        ST.TBool -> checkNoRequired md >> validateDefaultValAsBool dflt <&> TBool
        ST.TString -> checkNoDefault dflt $> TString (isRequired md)
        ST.TRef typeRef ->
          case findDecl currentNamespace symbolTables typeRef of
            MatchE (ns, enum) -> do
              checkNoRequired md
              validDefault <- validateDefaultAsEnum dflt enum
              pure $ TEnum (TypeRef ns (getIdent enum)) validDefault
            MatchS (ns, struct) -> checkNoDefault dflt $> TStruct (TypeRef ns (getIdent struct))  (isRequired md)
            MatchT (ns, table)  -> checkNoDefault dflt $> TTable  (TypeRef ns (getIdent table)) (isRequired md)
            MatchU (ns, union)  -> checkNoDefault dflt $> TUnion  (TypeRef ns (getIdent union)) (isRequired md)
            NoMatch checkedNamespaces -> typeRefNotFound checkedNamespaces typeRef
        ST.TVector vecType ->
          checkNoDefault dflt >> TVector (isRequired md) <$>
            case vecType of
              ST.TInt8 -> pure VInt8
              ST.TInt16 -> pure VInt16
              ST.TInt32 -> pure VInt32
              ST.TInt64 -> pure VInt64
              ST.TWord8 -> pure VWord8
              ST.TWord16 -> pure VWord16
              ST.TWord32 -> pure VWord32
              ST.TWord64 -> pure VWord64
              ST.TFloat -> pure VFloat
              ST.TDouble -> pure VDouble
              ST.TBool -> pure VBool
              ST.TString -> pure VString
              ST.TVector _ -> throwErrorMsg "nested vector types not supported"
              ST.TRef typeRef ->
                case findDecl currentNamespace symbolTables typeRef of
                  MatchE (ns, enum) ->
                    pure $ VEnum (TypeRef ns (getIdent enum))
                                 (fromIntegral @Word8 @InlineSize. enumSize $ enumType enum)
                  MatchS (ns, struct) ->
                    pure $ VStruct (TypeRef ns (getIdent struct))
                                   (structSize struct)
                  MatchT (ns, table) -> pure $ VTable (TypeRef ns (getIdent table))
                  MatchU (ns, union) -> pure $ VUnion (TypeRef ns (getIdent union))
                  NoMatch checkedNamespaces -> typeRefNotFound checkedNamespaces typeRef

checkNoRequired :: ValidationCtx m => ST.Metadata -> m ()
checkNoRequired md =
  when (hasAttribute "required" md) $
    throwErrorMsg "only non-scalar fields (strings, vectors, unions, structs, tables) may be 'required'"

checkNoDefault :: ValidationCtx m => Maybe ST.DefaultVal -> m ()
checkNoDefault dflt =
  when (isJust dflt) $
    throwErrorMsg
      "default values currently only supported for scalar fields (integers, floating point, bool, enums)"

isRequired :: ST.Metadata -> Required
isRequired md = if hasAttribute "required" md then Req else Opt

validateDefaultValAsInt :: forall m a. (ValidationCtx m, Integral a, Bounded a, Show a) => Maybe ST.DefaultVal -> m (DefaultVal a)
validateDefaultValAsInt dflt =
  case dflt of
    Nothing -> pure (DefaultVal 0)
    Just (ST.DefaultNum n) ->
      if not (Scientific.isInteger n)
        then throwErrorMsg "default value must be integral"
        else case Scientific.toBoundedInteger @a n of
          Nothing ->
            throwErrorMsg $
              "default value does not fit ["
              <> T.pack (show (minBound @a))
              <> "; "
              <> T.pack (show (maxBound @a))
              <> "]"
          Just i -> pure (DefaultVal i)
    Just _ -> throwErrorMsg "default value must be integral"

validateDefaultValAsScientific :: ValidationCtx m => Maybe ST.DefaultVal -> m (DefaultVal Scientific)
validateDefaultValAsScientific dflt =
  case dflt of
    Nothing                 -> pure (DefaultVal 0)
    Just (ST.DefaultNum n)  -> pure (DefaultVal n)
    Just _                  -> throwErrorMsg "default value must be a number"

validateDefaultValAsBool :: ValidationCtx m => Maybe ST.DefaultVal -> m (DefaultVal Bool)
validateDefaultValAsBool dflt =
  case dflt of
    Nothing                 -> pure (DefaultVal False)
    Just (ST.DefaultBool b) -> pure (DefaultVal b)
    Just _                  -> throwErrorMsg "default value must be a boolean"

validateDefaultAsEnum :: ValidationCtx m => Maybe ST.DefaultVal -> EnumDecl -> m (DefaultVal Ident)
validateDefaultAsEnum dflt enum =
  DefaultVal <$>
    case dflt of
      Nothing ->
        case find (\val -> enumValInt val == 0) (enumVals enum) of
          Just zeroVal -> pure (getIdent zeroVal)
          Nothing -> throwErrorMsg "enum does not have a 0 value; please manually specify a default for this field"
      Just (ST.DefaultNum n) ->
        case Scientific.floatingOrInteger n of
          Left _double -> throwErrorMsg $ "default value must be integral or " <> display (getIdent <$> enumVals enum)
          Right i -> 
            case find (\val -> enumValInt val == i) (enumVals enum) of
              Just matchingVal -> pure (getIdent matchingVal)
              Nothing -> throwErrorMsg $ "default value of " <> display i <> " is not part of enum " <> display (getIdent enum)
      Just (ST.DefaultRef ref) ->
        case find (\val -> getIdent val == ref) (enumVals enum) of
          Just _  -> pure ref
          Nothing -> throwErrorMsg $ "default value of " <> display ref <> " is not part of enum " <> display (getIdent enum)
      
      Just (ST.DefaultBool _) -> throwErrorMsg $ "default value must be integral or " <> display (getIdent <$> enumVals enum)


----------------------------------
------------ Unions --------------
----------------------------------
validateUnions :: ValidationCtx m => FileTree Stage4 -> m (FileTree ValidDecls)
validateUnions symbolTables =
  for symbolTables $ \symbolTable -> do
    let unions = allUnions symbolTable
    let validate (namespace, union) = do
          validUnion <- validateUnion symbolTables (namespace, union)
          pure (namespace, validUnion)
    validUnions <- traverse validate unions
    pure symbolTable { allUnions = validUnions }

validateUnion :: forall m. ValidationCtx m => FileTree Stage4 -> (Namespace, ST.UnionDecl) -> m UnionDecl
validateUnion symbolTables (currentNamespace, union) =
  local (\_ -> qualify currentNamespace (getIdent union)) $ do
    validUnionVals <- traverse validateUnionVal (ST.unionVals union)
    checkDuplicateVals validUnionVals
    pure $ UnionDecl
      { unionIdent = getIdent union
      , unionVals = validUnionVals
      }
  where
    validateUnionVal :: ST.UnionVal -> m UnionVal
    validateUnionVal uv = do
      let tref = ST.unionValTypeRef uv
      let partiallyQualifiedTypeRef = qualify (typeRefNamespace tref) (typeRefIdent tref)
      let ident = fromMaybe partiallyQualifiedTypeRef (ST.unionValIdent uv)
      let identFormatted = coerce $ T.replace "." "_" $ coerce ident
      local (\context -> context <> "." <> identFormatted) $ do
        tableRef <- validateUnionValType tref
        pure $ UnionVal
          { unionValIdent = identFormatted
          , unionValTableRef = tableRef
          }

    validateUnionValType :: TypeRef -> m TypeRef
    validateUnionValType typeRef =
      case findDecl currentNamespace symbolTables typeRef of
        NoMatch checkedNamespaces -> typeRefNotFound checkedNamespaces typeRef
        MatchT (ns, table)        -> pure $ TypeRef ns (getIdent table)
        _                         -> throwErrorMsg "union members may only be tables"

    checkDuplicateVals :: NonEmpty UnionVal -> m ()
    checkDuplicateVals vals = checkDuplicateIdentifiers (NE.cons "NONE" (fmap getIdent vals))


----------------------------------
------------ Structs -------------
----------------------------------
validateStructs :: ValidationCtx m => FileTree Stage2 -> m (FileTree Stage3)
validateStructs symbolTables =
  flip evalStateT [] $ traverse validateFile symbolTables
  where
  validateFile :: (MonadState [(Namespace, StructDecl)] m, ValidationCtx m) => Stage2 -> m Stage3
  validateFile symbolTable = do
    let structs = allStructs symbolTable

    traverse_ (checkStructCycles symbolTables) structs
    validStructs <- traverse (validateStruct symbolTables) structs

    pure symbolTable { allStructs = validStructs }

checkStructCycles :: forall m. ValidationCtx m => FileTree Stage2 -> (Namespace, ST.StructDecl) -> m ()
checkStructCycles symbolTables = go []
  where
    go :: [Ident] -> (Namespace, ST.StructDecl) -> m ()
    go visited (currentNamespace, struct) =
      let qualifiedName = qualify currentNamespace (getIdent struct)
      in  local (const qualifiedName) $
            if qualifiedName `elem` visited
              then
                throwErrorMsg $
                  "cyclic dependency detected ["
                  <> display (T.intercalate " -> " . coerce $ List.dropWhile (/= qualifiedName) $ List.reverse (qualifiedName : visited))
                  <>"] - structs cannot contain themselves, directly or indirectly"
              else
                forM_ (ST.structFields struct) $ \field ->
                  case ST.structFieldType field of
                    ST.TRef typeRef ->
                      case findDecl currentNamespace symbolTables typeRef of
                        MatchS struct ->
                          go (qualifiedName : visited) struct
                        _ ->
                          pure () -- The TypeRef points to an enum (or is invalid), so no further validation is needed at this point
                    _ -> pure () -- Field is not a TypeRef, no validation needed

data UnpaddedStructField = UnpaddedStructField
  { unpaddedStructFieldIdent    :: Ident
  , unpaddedStructFieldType     :: StructFieldType
  } deriving (Show, Eq)

validateStruct ::
     forall m. (MonadState [(Namespace, StructDecl)] m, ValidationCtx m)
  => FileTree Stage2
  -> (Namespace, ST.StructDecl)
  -> m (Namespace, StructDecl)
validateStruct symbolTables (currentNamespace, struct) =
  local (\_ -> qualify currentNamespace (getIdent struct)) $ do
    validStructs <- get
    -- Check if this struct has already been validated in a previous iteration
    case find (\(ns, s) -> ns == currentNamespace && getIdent s == getIdent struct) validStructs of
      Just match -> pure match
      Nothing -> do
        checkDuplicateFields

        fields <- traverse validateStructField (ST.structFields struct)
        let naturalAlignment = maximum (structFieldAlignment <$> fields)
        forceAlignAttr <- getForceAlignAttr
        forceAlign <- traverse (validateForceAlign naturalAlignment) forceAlignAttr
        let alignment = fromMaybe naturalAlignment forceAlign

        -- In order to calculate the padding between fields, we must first know the fields' and the struct's
        -- alignment. Which means we must first validate all the struct's fields, and then do a second
        -- pass to calculate the padding.
        let paddedFields = addFieldPadding alignment fields

        let validStruct = StructDecl
              { structIdent      = getIdent struct
              , structAlignment  = alignment
              , structFields     = paddedFields
              }
        modify ((currentNamespace, validStruct) :)
        pure (currentNamespace, validStruct)

  where
    invalidStructFieldType = "struct fields may only be integers, floating point, bool, enums, or other structs"

    addFieldPadding :: Word8 -> NonEmpty UnpaddedStructField -> NonEmpty StructField
    addFieldPadding structAlignment =
      NE.fromList . go 0 . NE.toList
      where
        go :: InlineSize -> [UnpaddedStructField] -> [StructField]
        go sizeAccum [] = []
        go sizeAccum (x : y : tail) =
          let sizeAccum' = sizeAccum + structFieldTypeSize (unpaddedStructFieldType x)
              nextFieldsAlignment = fromIntegral @Word8 @InlineSize (structFieldAlignment y)
              paddingNeeded = (sizeAccum' `roundUpToNearestMultipleOf` nextFieldsAlignment) - sizeAccum'
              sizeAccum'' = sizeAccum' + paddingNeeded
              paddedField = StructField (unpaddedStructFieldIdent x) (fromIntegral @InlineSize @Word8 paddingNeeded) (unpaddedStructFieldType x)
          in  paddedField : go sizeAccum'' (y : tail)
        go sizeAccum [x] =
          let sizeAccum' = sizeAccum + structFieldTypeSize (unpaddedStructFieldType x)
              structAlignment' = fromIntegral @Word8 @InlineSize structAlignment
              paddingNeeded = (sizeAccum' `roundUpToNearestMultipleOf` structAlignment') - sizeAccum'
          in  [StructField (unpaddedStructFieldIdent x) (fromIntegral @InlineSize @Word8 paddingNeeded) (unpaddedStructFieldType x)]

    validateStructField :: ST.StructField -> m UnpaddedStructField
    validateStructField sf =
      local (\context -> context <> "." <> getIdent sf) $ do
        checkUnsupportedAttributes sf
        structFieldType <- validateStructFieldType (ST.structFieldType sf)
        pure $ UnpaddedStructField
          { unpaddedStructFieldIdent = getIdent sf
          , unpaddedStructFieldType = structFieldType
          }

    validateStructFieldType :: ST.Type -> m StructFieldType
    validateStructFieldType structFieldType =
      case structFieldType of
        ST.TInt8 -> pure SInt8
        ST.TInt16 -> pure SInt16
        ST.TInt32 -> pure SInt32
        ST.TInt64 -> pure SInt64
        ST.TWord8 -> pure SWord8
        ST.TWord16 -> pure SWord16
        ST.TWord32 -> pure SWord32
        ST.TWord64 -> pure SWord64
        ST.TFloat -> pure SFloat
        ST.TDouble -> pure SDouble
        ST.TBool -> pure SBool
        ST.TString -> throwErrorMsg invalidStructFieldType
        ST.TVector _ -> throwErrorMsg invalidStructFieldType
        ST.TRef typeRef ->
          case findDecl currentNamespace symbolTables typeRef of
            MatchE (enumNamespace, enum) ->
              pure (SEnum (TypeRef enumNamespace (getIdent enum)) (enumType enum))
            MatchS (nestedNamespace, nestedStruct) ->
              -- if this is a reference to a struct, we need to validate it first
              SStruct <$> validateStruct symbolTables (nestedNamespace, nestedStruct)
            NoMatch checkedNamespaces ->
              typeRefNotFound checkedNamespaces typeRef
            _ -> throwErrorMsg invalidStructFieldType

    checkUnsupportedAttributes :: ST.StructField -> m ()
    checkUnsupportedAttributes structField = do
      when (hasAttribute "deprecated" (ST.structFieldMetadata structField)) $
        throwErrorMsg "can't deprecate fields in a struct"
      when (hasAttribute "required" (ST.structFieldMetadata structField)) $
        throwErrorMsg "struct fields are already required, the 'required' attribute is redundant"
      when (hasAttribute "id" (ST.structFieldMetadata structField)) $
        throwErrorMsg "struct fields cannot be reordered using the 'id' attribute"

    getForceAlignAttr :: m (Maybe Integer)
    getForceAlignAttr = findIntAttr "force_align" (ST.structMetadata struct)

    validateForceAlign :: Word8 -> Integer -> m Word8
    validateForceAlign naturalAlignment forceAlign =
      if isPowerOfTwo forceAlign
        && inRange (fromIntegral @Word8 @Integer naturalAlignment, 16) forceAlign
        then pure (fromIntegral @Integer @Word8 forceAlign)
        else throwErrorMsg $
              "force_align must be a power of two integer ranging from the struct's natural alignment (in this case, "
              <> T.pack (show naturalAlignment)
              <> ") to 16"

    checkDuplicateFields :: m ()
    checkDuplicateFields =
      checkDuplicateIdentifiers
        (ST.structFields struct)

----------------------------------
------------ Helpers -------------
----------------------------------
structFieldAlignment :: UnpaddedStructField -> Word8
structFieldAlignment usf =
  case unpaddedStructFieldType usf of
    SInt8 -> 1
    SInt16 -> 2
    SInt32 -> 4
    SInt64 -> 8
    SWord8 -> 1
    SWord16 -> 2
    SWord32 -> 4
    SWord64 -> 8
    SFloat -> 4
    SDouble -> 8
    SBool -> 1
    SEnum _ enumType -> enumAlignment enumType
    SStruct (_, nestedStruct) -> structAlignment nestedStruct

enumAlignment :: EnumType -> Word8
enumAlignment = enumSize

-- | The size of an enum is either 1, 2, 4 or 8 bytes, so its size fits in a Word8
enumSize :: EnumType -> Word8
enumSize e =
  case e of
    EInt8 -> 1
    EInt16 -> 2
    EInt32 -> 3
    EInt64 -> 4
    EWord8 -> 1
    EWord16 -> 2
    EWord32 -> 3
    EWord64 -> 4

structFieldTypeSize :: StructFieldType -> InlineSize
structFieldTypeSize sft =
  case sft of
    SInt8 -> 1
    SInt16 -> 2
    SInt32 -> 4
    SInt64 -> 8
    SWord8 -> 1
    SWord16 -> 2
    SWord32 -> 4
    SWord64 -> 8
    SFloat -> 4
    SDouble -> 8
    SBool -> 1
    SEnum _ enumType -> fromIntegral @Word8 @InlineSize (enumSize enumType)
    SStruct (_, nestedStruct) -> structSize nestedStruct

structFieldSize :: StructField -> InlineSize
structFieldSize sf =
  fromIntegral @Word8 @InlineSize (structFieldPadding sf) + structFieldTypeSize (structFieldType sf)

structSize :: StructDecl -> InlineSize
structSize struct =
  sum (structFieldSize <$> structFields struct)

checkDuplicateIdentifiers :: (ValidationCtx m, Foldable f, Functor f, HasIdent a) => f a -> m ()
checkDuplicateIdentifiers xs =
  case findDups (getIdent <$> xs) of
    [] -> pure ()
    dups ->
      throwErrorMsg $
        display dups <> " declared more than once"
  where
    findDups :: (Foldable f, Functor f, Ord a) => f a -> [a]
    findDups xs = Map.keys $ Map.filter (>1) $ occurrences xs

    occurrences :: (Foldable f, Functor f, Ord a) => f a -> Map a (Sum Int)
    occurrences xs =
      Map.unionsWith (<>) $ fmap (\x -> Map.singleton x (Sum 1)) xs

hasAttribute :: Text -> ST.Metadata -> Bool
hasAttribute name (ST.Metadata attrs) = Map.member name attrs

findIntAttr :: ValidationCtx m => Text -> ST.Metadata -> m (Maybe Integer)
findIntAttr name (ST.Metadata attrs) =
  case Map.lookup name attrs of
    Nothing                  -> pure Nothing
    Just Nothing             -> err
    Just (Just (ST.AttrI i)) -> pure (Just i)
    Just (Just (ST.AttrS t)) ->
      case readMaybe @Integer (T.unpack t) of
        Just i  -> pure (Just i)
        Nothing -> err
  where
    err = 
      throwErrorMsg $
        "expected attribute '"
        <> name
        <> "' to have an integer value, e.g. '"
        <> name
        <> ": 123'"

findStringAttr :: ValidationCtx m => Text -> ST.Metadata -> m (Maybe Text)
findStringAttr name (ST.Metadata attrs) =
  case Map.lookup name attrs of
    Nothing                  -> pure Nothing
    Just (Just (ST.AttrS s)) -> pure (Just s)
    Just _ ->
      throwErrorMsg $
        "expected attribute '"
        <> name
        <> "' to have a string value, e.g. '"
        <> name
        <> ": \"abc\"'"

throwErrorMsg :: ValidationCtx m => Text -> m a
throwErrorMsg msg = do
  context <- ask
  if context == ""
    then throwError msg
    else throwError $ "[" <> display context <> "]: " <> msg

typeRefNotFound :: ValidationCtx m => NonEmpty Namespace -> TypeRef -> m a
typeRefNotFound checkedNamespaces typeRef =
  throwErrorMsg $
    "type '"
    <> display typeRef
    <> "' does not exist (checked in these namespaces: "
    <> display checkedNamespaces
    <> ")"

