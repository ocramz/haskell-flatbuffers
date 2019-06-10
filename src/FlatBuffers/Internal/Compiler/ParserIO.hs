{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

module FlatBuffers.Internal.Compiler.ParserIO where

import           Control.Applicative                      ( (<|>) )
import           Control.Monad                            ( when )
import           Control.Monad.Except                     ( MonadError, MonadIO, liftIO, throwError )
import           Control.Monad.State                      ( MonadState, execStateT, get, put )

import           Data.Coerce                              ( coerce )
import           Data.Foldable                            ( traverse_ )
import qualified Data.List                                as List
import           Data.Map.Strict                          ( Map )
import qualified Data.Map.Strict                          as Map
import           Data.Text                                ( Text )
import qualified Data.Text                                as T

import           FlatBuffers.Internal.Compiler.Parser     ( schema )
import           FlatBuffers.Internal.Compiler.SyntaxTree ( FileTree(..), Include(..), Schema, StringLiteral(..), includes )
import           FlatBuffers.Internal.Display             ( display )

import qualified System.Directory                         as Dir
import qualified System.FilePath                          as FP
import           System.FilePath                          ( (</>) )

import           Text.Megaparsec                          ( errorBundlePretty, parse )

parseSchemas ::
     MonadIO m
  => MonadError Text m
  => FilePath -- ^ Filepath of the root schema. It must be a path relative to the project root or an absolute path.
  -> [FilePath] -- ^ Directories to search for @include@s.
  -> m (FileTree Schema)
parseSchemas rootFilePath includeDirs = do
  fileContent <- liftIO $ readFile rootFilePath
  case parse schema rootFilePath fileContent of
    Left err -> throwError . T.pack . errorBundlePretty $ err
    Right rootSchema -> do
      rootFilePathCanon <- liftIO $ Dir.canonicalizePath rootFilePath
      let importedFilePaths = T.unpack . coerce <$> includes rootSchema

      importedSchemas <- flip execStateT Map.empty $
                            traverse_
                              (parseImportedSchema includeDirs rootFilePathCanon)
                              importedFilePaths
      pure FileTree
            { fileTreeFilePath = rootFilePathCanon
            , fileTreeRoot     = rootSchema
            , fileTreeForest   = importedSchemas
            }

parseImportedSchema ::
     MonadState (Map FilePath Schema) m
  => MonadIO m
  => MonadError Text m
  => [FilePath]
  -> FilePath
  -> FilePath
  -> m ()
parseImportedSchema includeDirs rootFilePathCanon filePath =
  go rootFilePathCanon filePath
  where
    go parentSchemaPath filePath = do

      let parentSchemaDir = FP.takeDirectory parentSchemaPath
      let dirCandidates = parentSchemaDir : includeDirs

      actualFilePathCanonMaybe <- liftIO $ Dir.findFile dirCandidates filePath >>= traverse Dir.canonicalizePath

      case actualFilePathCanonMaybe of
        Nothing -> throwError $
          "File '"
          <> T.pack filePath
          <> "' (imported from '"
          <> T.pack parentSchemaPath
          <> "') not found.\n Searched in these directories: ["
          <> display (T.pack <$> dirCandidates)
          <> "]"
        Just actualFilePathCanon -> do
          importedSchemas <- get
          when (actualFilePathCanon /= rootFilePathCanon && actualFilePathCanon `Map.notMember` importedSchemas) $ do
            fileContent <- liftIO $ readFile actualFilePathCanon
            case parse schema actualFilePathCanon fileContent of
              Left err -> throwError . T.pack . errorBundlePretty $ err
              Right importedSchema -> do
                put (Map.insert actualFilePathCanon importedSchema importedSchemas)
                traverse_ (go actualFilePathCanon . T.unpack . coerce) (includes importedSchema)
