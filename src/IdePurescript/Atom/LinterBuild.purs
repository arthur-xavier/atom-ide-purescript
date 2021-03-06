module IdePurescript.Atom.LinterBuild where

import Prelude
import Atom.Atom (getAtom)
import Atom.Config (Config, CONFIG, getConfig)
import Atom.NotificationManager (NOTIFY, addError)
import Control.Monad.Aff (Aff)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Console (CONSOLE, log, error)
import Control.Monad.Eff.Exception (Error)
import Control.Monad.Eff.Ref (REF)
import Control.Monad.Error.Class (catchError)
import Control.Monad.Except (runExcept)
import DOM (DOM)
import DOM.Node.Types (Element)
import Data.Array (filter, notElem, uncons)
import Data.Either (Either(Right), either)
import Data.Foreign (readArray, readString)
import Data.Maybe (Maybe(Nothing, Just), maybe)
import Data.String (trim)
import Data.String.Regex (regex, split)
import Data.String.Regex.Flags (noFlags)
import Data.Traversable (traverse)
import IdePurescript.Atom.Build (AtomLintMessage, linterBuild, toLintResult)
import IdePurescript.Atom.BuildStatus (BuildStatus(Failure, Errors, Success, Building), updateBuildStatus)
import IdePurescript.Atom.Config (getFastRebuild)
import IdePurescript.Atom.Hooks.Linter (LinterIndie, LINTER, setMessages, deleteMessages)
import IdePurescript.Build (BuildResult, rebuild)
import Node.Buffer (BUFFER)
import Node.ChildProcess (CHILD_PROCESS)
import Node.FS (FS) as FS
import Node.Process (PROCESS)
import PscIde (NET)

type LintEff e = (buffer :: BUFFER, fs :: FS.FS, process :: PROCESS, cp :: CHILD_PROCESS, console :: CONSOLE, ref :: REF, config :: CONFIG, note :: NOTIFY, linter :: LINTER, dom :: DOM, net :: NET | e)

lint :: forall eff. Maybe Int -> Maybe String -> Config -> String -> LinterIndie -> Element -> Aff (LintEff eff) (Maybe (Array AtomLintMessage))
lint port file config projdir linter statusElt = do
  atom <- liftEff getAtom
  fullBuildPath <- liftEff $ getConfig config "ide-purescript.buildCommand"
  let pathStr = either
  let buildCommand = case regex "\\s+" noFlags, runExcept $ readString fullBuildPath of
                      Right r, Right s -> split r $ trim $ s
                      _, _ -> []

  isFastBuild <- liftEff getFastRebuild
  let fastBuild :: Maybe (Aff (LintEff eff) BuildResult)
      fastBuild = case isFastBuild, file, port of
        true, Just fileName, Just p -> Just $ rebuild p fileName
        _, _, _ -> Nothing
  pure unit

  case fastBuild, uncons buildCommand of
    Just cmd, _ -> doBuild cmd
    _, Just { head: command, tail: args } -> doBuild $ linterBuild { command, args, directory: projdir }
    _, Nothing -> (do
      liftEff $ failure "Error parsing PureScript build command"
      pure Nothing)
  where

    doBuild :: (Aff (LintEff eff) BuildResult) -> Aff (LintEff eff) (Maybe (Array AtomLintMessage))
    doBuild buildCmd =
      do
        liftEff $ status Building Nothing
        { result, messages } <- toLintResult <$> buildCmd
        liftEff $ Just <$> do
          censorCodes <- liftEff $ getConfig config "ide-purescript.censorWarnings"
          let codes = either (const []) id $ runExcept $ readArray censorCodes >>= traverse readString
          let messages' = filter (flip notElem codes <<< _.errorCode) messages
          deleteMessages linter
          setMessages linter messages'
          status (if result == "success" then Success else Errors) Nothing
          pure messages'
      `catchError` \(e :: Error) -> do
        liftEff $ failure $ "Error running PureScript build command: " <> show e
        pure Nothing

    failure :: String -> Eff (LintEff eff) Unit
    failure s = do
      atom <- getAtom
      status Failure $ Just s
      addError atom.notifications s

    status :: BuildStatus -> (Maybe String) -> Eff (LintEff eff) Unit
    status s msg = do
      updateBuildStatus statusElt s
      (if s == Failure then error else log) $ "PureScript build status: " <> show s <> (maybe "" (": " <> _)  msg)
