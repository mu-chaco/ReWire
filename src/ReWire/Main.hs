{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE Safe #-}
module ReWire.Main (main) where

import ReWire.FrontEnd (loadProgram, LoadPath)
import ReWire.Pretty (prettyPrint)
import ReWire.Core.ToMiniHDL (compileProgram)
import ReWire.Flags (Flag (..))
import ReWire.Error (runSyntaxError)

import Control.Monad.IO.Class (liftIO)
import Control.Monad (when, unless)
import Data.List (intercalate)
import Data.List.Split (splitOn)
import System.Console.GetOpt (getOpt, usageInfo, OptDescr (..), ArgOrder (..), ArgDescr (..))
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath ((-<.>))
import System.IO (hPutStr, hPutStrLn, hPrint, stderr)

import Paths_ReWire (getDataFileName)

options :: [OptDescr Flag]
options =
       [ Option ['v'] ["verbose"]  (NoArg FlagV)       "More verbose output."
       , Option []    ["dhask1"]   (NoArg FlagDHask1)  "Dump pre-desugar haskell."
       , Option []    ["dhask2"]   (NoArg FlagDHask2)  "Dump post-desugar haskell."
       , Option []    ["dcrust1"]  (NoArg FlagDCrust1) "Dump post-desugar crust."
       , Option []    ["dcrust2"]  (NoArg FlagDCrust2) "Dump pre-purify crust."
       , Option []    ["dcrust3"]  (NoArg FlagDCrust3) "Dump post-purify crust."
       , Option []    ["dcrust4"]  (NoArg FlagDCrust4) "Dump post-second-lambda-lifting crust."
       , Option []    ["dcore"]    (NoArg FlagDCore)   "Dump core."
       , Option []    ["dtypes"]   (NoArg FlagDTypes)  "Enable extra typechecking after various IR transformations."
       , Option ['o'] []           (ReqArg FlagO "filename.vhd")
            "Name for VHDL output file."
       , Option []    ["loadpath"] (ReqArg FlagLoadPath "dir1,dir2,...")
            "Additional directories for loadpath."
       ]

exitUsage :: IO ()
exitUsage = hPutStr stderr (usageInfo "Usage: rwc [OPTION...] <filename.rw>" options) >> exitFailure

getSystemLoadPath :: IO [FilePath]
getSystemLoadPath = do
      lib <- getDataFileName "src/lib"
      rwlib <- getDataFileName "src/rwlib"
      pure $ "." : [lib, rwlib]

main :: IO ()
main = do
      (flags, filenames, errs) <-  getOpt Permute options <$> getArgs

      unless (null errs) $ do
            mapM_ (hPutStrLn stderr) errs
            exitUsage

      let userLP                   =  concatMap getLoadPathEntries flags
      systemLP                     <- getSystemLoadPath
      let lp                       =  userLP ++ systemLP

      when (FlagV `elem` flags) $ putStrLn ("loadpath: " ++ intercalate "," lp)

      mapM_ (compileFile flags $ userLP ++ systemLP) filenames

      where getOutFile :: [Flag] -> String -> IO String
            getOutFile flags filename = case filter (\ case { FlagO {} -> True; _ -> False }) flags of
                  []        -> pure $ filename -<.> "vhdl"
                  [FlagO o] -> pure o
                  _         -> hPutStrLn stderr "Multiple output files specified on the command line!" >> exitFailure

            getLoadPathEntries :: Flag -> [FilePath]
            getLoadPathEntries (FlagLoadPath ds) =  splitOn "," ds
            getLoadPathEntries _                 =  []

            compileFile :: [Flag] -> LoadPath -> String -> IO ()
            compileFile flags lp filename = do
                  when (FlagV `elem` flags) $ putStrLn $ "Compiling: " ++ filename

                  fout <- getOutFile flags filename

                  runSyntaxError (loadProgram flags lp filename >>= compileProgram >>= liftIO . writeFile fout . prettyPrint)
                        >>= either ((>> exitFailure) . hPrint stderr) pure
