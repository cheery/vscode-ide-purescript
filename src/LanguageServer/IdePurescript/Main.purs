module LanguageServer.IdePurescript.Main where

import Prelude
import Control.Monad.Aff (Aff, runAff)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Ref (modifyRef, newRef, readRef, writeRef)
import Control.Promise (Promise, fromAff)
import Data.Array (length)
import Data.Foreign (toForeign)
import Data.Maybe (Maybe(..), maybe)
import Data.Newtype (over, un, unwrap)
import Data.Nullable (toMaybe, toNullable)
import Data.StrMap (empty, insert)
import IdePurescript.Modules (Module, getModulesForFile, initialModulesState)
import IdePurescript.PscIdeServer (ErrorLevel(..), Notify)
import LanguageServer.Console (error, info, log, warn)
import LanguageServer.DocumentStore (getDocument, onDidSaveDocument)
import LanguageServer.Handlers (onCodeAction, onCompletion, onDefinition, onDidChangeConfiguration, onDocumentSymbol, onExecuteCommand, onHover, onWorkspaceSymbol, publishDiagnostics)
import LanguageServer.IdePurescript.Assist (addClause, caseSplit)
import LanguageServer.IdePurescript.Build (getDiagnostics)
import LanguageServer.IdePurescript.CodeActions (getActions, onReplaceSuggestion)
import LanguageServer.IdePurescript.Commands (addClauseCmd, addCompletionImportCmd, caseSplitCmd, cmdName, commands, replaceSuggestionCmd)
import LanguageServer.IdePurescript.Completion (getCompletions)
import LanguageServer.IdePurescript.Imports (addCompletionImport)
import LanguageServer.IdePurescript.Server (retry, startServer')
import LanguageServer.IdePurescript.Symbols (getDefinition, getDocumentSymbols, getWorkspaceSymbols)
import LanguageServer.IdePurescript.Tooltips (getTooltips)
import LanguageServer.IdePurescript.Types (ServerState(..), MainEff)
import LanguageServer.Setup (InitParams(..), initConnection, initDocumentStore)
import LanguageServer.TextDocument (getText, getUri)
import LanguageServer.Types (DocumentUri(..), Settings, TextDocumentIdentifier(..))
import LanguageServer.Uri (uriToFilename)
import PscIde (load)

defaultServerState :: forall eff. ServerState eff
defaultServerState = ServerState
  { port: Nothing
  , deactivate: pure unit
  , root: Nothing
  , conn: Nothing
  , modules: initialModulesState
  , diagnostics: empty
  }

main :: forall eff. Eff (MainEff eff) Unit
main = do
  state <- newRef defaultServerState
  config <- newRef (toForeign {})

  let logError :: Notify (MainEff eff)
      logError l s = do
        (_.conn <$> unwrap <$> readRef state) >>=
          maybe (pure unit) (\conn -> case l of 
            Success -> log conn s
            Info -> info conn s
            Warning -> warn conn s
            Error -> error conn s)
  let launchAffLog = void <<< runAff (logError Error <<< show) (const $ pure unit)

  let deactivate :: Eff (MainEff eff) Unit
      deactivate = do
        join $ _.deactivate <$> unwrap <$> readRef state
        modifyRef state (over ServerState $ _ { port = Nothing, deactivate = pure unit })

      startPscIdeServer = void $ runAff (const $ pure unit) (const $ pure unit) do
        rootPath <- liftEff $ (_.root <<< unwrap) <$> readRef state
        settings <- liftEff $ readRef config
        startRes <- startServer' settings rootPath logError logError
        retry logError 6 case startRes of
          { port: Just port, quit } -> do
            _ <- load port [] []
            liftEff $ modifyRef state (over ServerState $ _ { port = Just port, deactivate = quit })
            liftEff $ logError Success "Started psc-ide server"
          _ -> pure unit

  conn <- initConnection commands $ \({ params: InitParams { rootPath }, conn }) ->  do
    modifyRef state (over ServerState $ _ { root = toMaybe rootPath })
    startPscIdeServer
  modifyRef state (over ServerState $ _ { conn = Just conn })

  onDidChangeConfiguration conn $ writeRef config <<< _.settings

  log conn "PureScript Language Server started"

  documents <- initDocumentStore conn

  let showModule :: Module -> String
      showModule = unwrap >>> case _ of
         { moduleName, importType, qualifier } -> moduleName <> maybe "" (" as " <> _) qualifier

  let updateModules :: DocumentUri -> Aff (MainEff eff) Unit
      updateModules uri = 
        liftEff (readRef state) >>= case _ of 
          ServerState { port: Just port } -> do
            -- TODO
            _ <- load port [] []
            text <- liftEff $ getDocument documents uri >>= getText
            path <- liftEff $ uriToFilename uri
            modules <- getModulesForFile port path text
            liftEff $ modifyRef state $ over ServerState (_ { modules = modules })
            liftEff $ info conn $ "Updated modules to: " <> show modules.main <> " / " <> show (showModule <$> modules.modules)
          _ -> pure unit

  let runHandler :: forall a b . (b -> Maybe DocumentUri) -> (Settings -> ServerState (MainEff eff) -> b -> Aff (MainEff eff) a) -> b -> Eff (MainEff eff) (Promise a)
      runHandler docUri f b =
        fromAff do
          c <- liftEff $ readRef config
          s <- liftEff $ readRef state
          liftEff $ maybe (pure unit) (\con -> log con "handler") (_.conn $ unwrap s)
          maybe (pure unit) updateModules (docUri b)          
          f c s b

  let getTextDocUri :: forall r. { textDocument :: TextDocumentIdentifier | r } -> Maybe DocumentUri
      getTextDocUri = (Just <<< _.uri <<< un TextDocumentIdentifier <<< _.textDocument)

  onCompletion conn $ runHandler getTextDocUri (getCompletions documents)
  onDefinition conn $ runHandler getTextDocUri (getDefinition documents)
  onDocumentSymbol conn $ runHandler getTextDocUri getDocumentSymbols
  onWorkspaceSymbol conn $ runHandler (const Nothing) getWorkspaceSymbols
  onHover conn $ runHandler getTextDocUri (getTooltips documents)
  onCodeAction conn $ runHandler getTextDocUri (getActions documents)

  onDidSaveDocument documents \{ document } -> launchAffLog do
    let uri = getUri document
    c <- liftEff $ readRef config
    s <- liftEff $ readRef state
    { pscErrors, diagnostics } <- getDiagnostics uri c s
    let state' = over ServerState (\s1 -> s1 { diagnostics = insert (un DocumentUri uri) pscErrors (s1.diagnostics) }) s
    liftEff $ writeRef state state'
    liftEff $ publishDiagnostics conn { uri, diagnostics }
    liftEff $ info conn $ "Published " <> (show $ length diagnostics) <> " issues"

  onExecuteCommand conn $ \{command, arguments} -> do 
    fromAff do
      c <- liftEff $ readRef config
      s <- liftEff $ readRef state
      let noResult = toForeign $ toNullable Nothing
      case command of 
        _ | command == cmdName addCompletionImportCmd ->
          addCompletionImport documents logError c s arguments
        _ | command == cmdName caseSplitCmd ->
          caseSplit documents c s arguments $> noResult
        _ | command == cmdName addClauseCmd ->
          addClause documents c s arguments $> noResult
        _ | command == cmdName replaceSuggestionCmd ->
          onReplaceSuggestion documents c s arguments $> noResult
        _ -> do
              liftEff $ error conn $ "Unknown command: " <> command
              pure noResult