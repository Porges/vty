{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts, FlexibleInstances #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Vty supports a configuration file format and associated 'Config'
-- data type. The 'Config' can be provided to 'mkVty' to customize the
-- application's use of Vty.
--
-- Lines in config files that fail to parse are ignored. Later entries
-- take precedence over earlier ones.
--
-- = Debug
--
-- == @debugLog@
--
-- Format:
--
-- @
--  \"debugLog\" string
-- @
--
-- The value of the environment variable @VTY_DEBUG_LOG@ is equivalent
-- to a debugLog entry at the end of the last config file.
--
-- = Input Processing
--
-- == @map@
--
-- Format:
--
-- @
--  \"map\" term string key modifier_list
--  where
--      key := KEsc | KChar Char | KBS ... (same as 'Key')
--      modifier_list := \"[\" modifier+ \"]\"
--      modifier := MShift | MCtrl | MMeta | MAlt
--      term := "_" | string
-- @
--
-- E.g., if the contents are
--
-- @
--  map _       \"\\ESC[B\"    KUp   []
--  map _       \"\\ESC[1;3B\" KDown [MAlt]
--  map \"xterm\" \"\\ESC[D\"    KLeft []
-- @
--
-- Then the bytes @\"\\ESC[B\"@ will result in the KUp event on all
-- terminals. The bytes @\"\\ESC[1;3B\"@ will result in the event KDown
-- with the MAlt modifier on all terminals. The bytes @\"\\ESC[D\"@ will
-- result in the KLeft event when @TERM@ is @xterm@.
--
-- If a debug log is requested then vty will output the current input
-- table to the log in the above format. A workflow for using this is
-- to set @VTY_DEBUG_LOG@. Run the application. Check the debug log for
-- incorrect mappings. Add corrected mappings to @$HOME/.vty/config@.
module Graphics.Vty.Config
  ( InputMap
  , Config(..)
  , VtyConfigurationError(..)
  , userConfig
  , overrideEnvConfig
  , standardIOConfig
  , runParseConfig
  , parseConfigFile
  , defaultConfig
  )
where

import Prelude

import Control.Applicative hiding (many)

import Control.Exception (catch, IOException, Exception(..), throwIO)
import Control.Monad (liftM, guard, void)

import qualified Data.ByteString as BS
import Data.Monoid
import Data.Typeable (Typeable)

import Graphics.Vty.Input.Events

import GHC.Generics

import System.Directory (getAppUserDataDirectory)
import System.Posix.Env (getEnv)
import System.Posix.IO (stdInput, stdOutput)
import System.Posix.Types (Fd(..))

import Text.Parsec hiding ((<|>))
import Text.Parsec.Token ( GenLanguageDef(..) )
import qualified Text.Parsec.Token as P

-- | Type of errors that can be thrown when configuring VTY
data VtyConfigurationError
  = VtyMissingTermEnvVar -- ^ TERM environment variable not set
  deriving (Show, Eq, Typeable)

instance Exception VtyConfigurationError where
  displayException VtyMissingTermEnvVar = "TERM environment variable not set"

-- | Mappings from input bytes to event in the order specified. Later
-- entries take precedence over earlier in the case multiple entries
-- have the same byte string.
type InputMap = [(Maybe String, String, Event)]

-- | A Vty configuration.
data Config = Config
    {
    -- | The default is 1 character.
      vmin  :: Maybe Int
    -- | The default is 100 milliseconds, 0.1 seconds.
    , vtime :: Maybe Int
    -- | The default is False.
    , mouseMode :: Maybe Bool
    -- | The default is False.
    , bracketedPasteMode :: Maybe Bool
    -- | Debug information is appended to this file if not Nothing.
    , debugLog           :: Maybe FilePath
    -- | The (input byte, output event) pairs extend the internal input
    -- table of VTY and the table from terminfo.
    --
    -- See "Graphics.Vty.Config" module documentation for documentation
    -- of the @map@ directive.
    , inputMap           :: InputMap
    -- | The input file descriptor to use. The default is
    -- 'System.Posix.IO.stdInput'
    , inputFd           :: Maybe Fd
    -- | The output file descriptor to use. The default is
    -- 'System.Posix.IO.stdOutput'
    , outputFd          :: Maybe Fd
    -- | The terminal name used to look up terminfo capabilities.
    -- The default is the value of the TERM environment variable.
    , termName           :: Maybe String
    } deriving (Show, Eq)

defaultConfig :: Config
defaultConfig = mempty

instance Monoid Config where
    mempty = Config
        { vmin         = Nothing
        , vtime        = Nothing
        , mouseMode    = Nothing
        , bracketedPasteMode = Nothing
        , debugLog     = mempty
        , inputMap     = mempty
        , inputFd     = Nothing
        , outputFd    = Nothing
        , termName     = Nothing
        }
    mappend c0 c1 = Config
        -- latter config takes priority for everything but inputMap
        { vmin          = vmin c1     <|> vmin c0
        , vtime         = vtime c1    <|> vtime c0
        , mouseMode     = mouseMode c1
        , bracketedPasteMode = bracketedPasteMode c1
        , debugLog      = debugLog c1 <|> debugLog c0
        , inputMap      = inputMap c0 <>  inputMap c1
        , inputFd      = inputFd c1 <|> inputFd c0
        , outputFd     = outputFd c1 <|> outputFd c0
        , termName      = termName c1 <|> termName c0
        }

-- | Load a configuration from @'getAppUserDataDirectory'/config@ and
-- @$VTY_CONFIG_FILE@.
userConfig :: IO Config
userConfig = do
    configFile <- (mappend <$> getAppUserDataDirectory "vty" <*> pure "/config") >>= parseConfigFile
    overrideConfig <- maybe (return defaultConfig) parseConfigFile =<< getEnv "VTY_CONFIG_FILE"
    let base = configFile <> overrideConfig
    mappend base <$> overrideEnvConfig

overrideEnvConfig :: IO Config
overrideEnvConfig = do
    d <- getEnv "VTY_DEBUG_LOG"
    return $ defaultConfig { debugLog = d }

-- | Configures VTY using defaults suitable for terminals. This function
-- can raise 'VtyConfigurationError'.
standardIOConfig :: IO Config
standardIOConfig = do
    mb <- getEnv "TERM"
    case mb of
      Nothing -> throwIO VtyMissingTermEnvVar
      Just t ->
        return defaultConfig
          { vmin               = Just 1
          , mouseMode          = Just False
          , bracketedPasteMode = Just False
          , vtime              = Just 100
          , inputFd            = Just stdInput
          , outputFd           = Just stdOutput
          , termName           = Just t
          }

parseConfigFile :: FilePath -> IO Config
parseConfigFile path = do
    catch (runParseConfig path <$> BS.readFile path)
          (\(_ :: IOException) -> return defaultConfig)

runParseConfig :: String -> BS.ByteString -> Config
runParseConfig name cfgTxt =
  case runParser parseConfig () name cfgTxt of
    Right cfg -> cfg
    Left{}    -> defaultConfig

------------------------------------------------------------------------

type Parser = Parsec BS.ByteString ()

configLanguage :: Monad m => P.GenLanguageDef BS.ByteString () m
configLanguage = LanguageDef
    { commentStart    = "{-"
    , commentEnd      = "-}"
    , commentLine     = "--"
    , nestedComments  = True
    , identStart      = letter <|> char '_'
    , identLetter     = alphaNum <|> oneOf "_'"
    , opStart         = opLetter configLanguage
    , opLetter        = oneOf ":!#$%&*+./<=>?@\\^|-~"
    , reservedOpNames = []
    , reservedNames   = []
    , caseSensitive   = True
    }

configLexer :: Monad m => P.GenTokenParser BS.ByteString () m
configLexer = P.makeTokenParser configLanguage

mapDecl :: Parser Config
mapDecl = do
    "map" <- P.identifier configLexer
    termIdent <- (char '_' >> P.whiteSpace configLexer >> return Nothing)
             <|> (Just <$> P.stringLiteral configLexer)
    bytes     <- P.stringLiteral configLexer
    key       <- parseValue
    modifiers <- parseValue
    return defaultConfig { inputMap = [(termIdent, bytes, EvKey key modifiers)] }

debugLogDecl :: Parser Config
debugLogDecl = do
    "debugLog" <- P.identifier configLexer
    path       <- P.stringLiteral configLexer
    return defaultConfig { debugLog = Just path }

ignoreLine :: Parser ()
ignoreLine = void $ manyTill anyChar newline

parseConfig :: Parser Config
parseConfig = liftM mconcat $ many $ do
    P.whiteSpace configLexer
    let directives = [try mapDecl, try debugLogDecl]
    choice directives <|> (ignoreLine >> return defaultConfig)

class    Parse a        where parseValue :: Parser a
instance Parse Char     where parseValue = P.charLiteral configLexer
instance Parse Int      where parseValue = fromInteger <$> P.natural configLexer
instance Parse Key      where parseValue = genericParse
instance Parse Modifier where parseValue = genericParse
instance Parse a => Parse [a] where
  parseValue = P.brackets configLexer
                 (parseValue `sepBy` P.symbol configLexer ",")

------------------------------------------------------------------------
-- Derived parser for ADTs via generics
------------------------------------------------------------------------

genericParse :: (Generic a, GParse (Rep a)) => Parser a
genericParse = to <$> gparse

class    GParse f                      where gparse :: Parser (f a)
instance GParse f => GParse (M1 S i f) where gparse = M1 <$> gparse
instance GParse U1                     where gparse = return U1
instance Parse a => GParse (K1 i a)    where gparse = K1 <$> parseValue

instance (GParse f, GParse g) => GParse (f :*: g) where
  gparse = (:*:) <$> gparse <*> gparse

instance GParseAlts f => GParse (M1 D i f) where
  gparse =
    do con <- P.identifier configLexer
       M1 <$> gparseAlts con

------------------------------------------------------------------------

class GParseAlts f where
  gparseAlts :: String -> Parser (f a)

instance (Constructor i, GParse f) => GParseAlts (M1 C i f) where
  gparseAlts con =
    do guard (con == conName (M1 Nothing :: C1 i Maybe a))
       M1 <$> gparse

instance (GParseAlts f, GParseAlts g) => GParseAlts (f :+: g) where
  gparseAlts con = L1 <$> gparseAlts con <|> R1 <$> gparseAlts con

instance GParseAlts V1 where gparseAlts _ = fail "GParse: V1"
