{-# LANGUAGE CPP, RecordWildCards #-}

-- | The entry point of the library
module Language.Haskell.Ghcid(
    Ghci, GhciError(..),
    Load(..), Severity(..),
    startGhci, stopGhci, interrupt, execStream,
    showModules, reload, exec
    ) where

import System.IO
import System.IO.Error
import System.Process
import System.Time.Extra
import Control.Concurrent.Extra
import Control.Exception.Extra
import Control.Monad.Extra
import Data.Function
import Data.List
import Data.Maybe
import Data.IORef
import Control.Applicative

import System.Console.CmdArgs.Verbosity
#if !defined(mingw32_HOST_OS)
import System.Posix.Signals
#endif

import Language.Haskell.Ghcid.Parser
import Language.Haskell.Ghcid.Types as T
import Language.Haskell.Ghcid.Util
import Prelude


-- | A GHCi session. Created with 'startGhci'.
data Ghci = Ghci
    {ghciProcess :: ProcessHandle
    ,ghciInterupt :: IO ()
    ,ghciExec :: String -> IO [String]}


-- | Start GHCi, returning a function to perform further operation, as well as the result of the initial loading.
--   The callback will be given the messages produced while loading, useful if invoking something like "cabal repl"
--   which might compile dependent packages before really loading.
startGhci :: String -> Maybe FilePath -> (String -> IO ()) -> IO (Ghci, [Load])
startGhci cmd directory echo = do
    (Just inp, Just out, Just err, ghciProcess) <-
        createProcess (shell cmd){std_in=CreatePipe, std_out=CreatePipe, std_err=CreatePipe, cwd=directory, create_group=True}

    hSetBuffering out LineBuffering
    hSetBuffering err LineBuffering
    hSetBuffering inp LineBuffering

    let prefix = "#~GHCID-START~#"
    let finish = "#~GHCID-FINISH~#"
    hPutStrLn inp $ ":set prompt " ++ prefix
    hPutStrLn inp ":set -fno-break-on-exception -fno-break-on-error" -- see #43

    lock <- newLock -- ensure only one person talks to ghci at a time
    echo <- newVar echo -- where to write the output
    isRunning <- newIORef False

    -- consume from a handle, produce an MVar with either Just and a message, or Nothing (stream closed)
    let consume h name = do
            result <- newEmptyMVar -- the end result
            buffer <- newVar [] -- the things to go in result
            forkIO $ fix $ \rec -> do
                el <- tryBool isEOFError $ hGetLine h
                case el of
                    Left _ -> putMVar result Nothing
                    Right l -> do
                        whenLoud $ outStrLn $ "%" ++ name ++ ": " ++ l
                        unless (any (`isInfixOf` l) [prefix, finish]) $ withVar echo ($ l)
                        if finish `isInfixOf` l
                          then do
                            buf <- modifyVar buffer $ \old -> return ([], reverse old)
                            putMVar result $ Just buf
                          else
                            modifyVar_ buffer $ return . (dropPrefixRepeatedly prefix l:)
                        rec
            return result

    outs <- consume out "GHCOUT"
    errs <- consume err "GHCERR"

    let ghciExec s = do
            withLock lock $ do
                whenLoud $ outStrLn $ "%GHCINP: " ++ s
                writeIORef isRunning True
                hPutStrLn inp $ s ++ "\nPrelude.putStrLn " ++ show finish ++ "\nPrelude.error " ++ show finish
                outC <- takeMVar outs
                errC <- takeMVar errs
                writeIORef isRunning False
                case liftM2 (++) outC errC of
                    Nothing -> throwIO $ UnexpectedExit cmd s
                    Just msg -> return msg

    let ghciInterupt = whenM (readIORef isRunning) $ do
                whenLoud $ outStrLn "%INTERRUPTED"
                ignore $ interruptProcessGroupOf ghciProcess
                writeIORef isRunning False

    let ghci = Ghci{..}
#if !defined(mingw32_HOST_OS)
    tid <- myThreadId
    installHandler sigINT (Catch (interrupt ghci >> stopGhci ghci >> throwTo tid UserInterrupt)) Nothing
#endif
    r <- parseLoad <$> ghciExec ""
    modifyVar_ echo $ \old -> return $ \s -> return ()

    return (ghci, r)

-- | Stop GHCi
stopGhci :: Ghci -> IO ()
stopGhci ghci = do
    handle (\UnexpectedExit{} -> return ()) $ void $ exec ghci ":quit"
    void $ forkIO $ ignore $ do
        sleep 1 -- try and give ghci a chance to go quietly
        interruptProcessGroupOf $ ghciProcess ghci
        sleep 5 -- give the process a few seconds grace period to die nicely
        terminateProcess $ ghciProcess ghci
    void $ waitForProcess $ ghciProcess ghci

-- | Execute a command, calling a callback on each response.
--   The callback will be called single threaded.
execStream :: Ghci -> String -> (String -> IO ()) -> IO ()
execStream ghci cmd echo = do
    res <- ghciExec ghci cmd
    mapM_ echo res

-- | Interrupt Ghci, stopping the current task, but leaving the process open to new input.
interrupt :: Ghci -> IO ()
interrupt = ghciInterupt


---------------------------------------------------------------------
-- SUGAR HELPERS

-- | Send a command, get lines of result
exec :: Ghci -> String -> IO [String]
exec ghci cmd = do
    ref <- newIORef []
    execStream ghci cmd $ \s -> modifyIORef ref (s:)
    reverse <$> readIORef ref

-- | Show modules
showModules :: Ghci -> IO [(String,FilePath)]
showModules ghci = parseShowModules <$> exec ghci ":show modules"

-- | reload modules
reload :: Ghci -> IO [Load]
reload ghci = parseLoad <$> exec ghci ":reload"
