{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE CPP #-}
module HADFS where

import ADLDAP
import ADLDAP.Types
import ADLDAP.Utils
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
--import Control.Monad.Reader
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import System.PosixCompat.Types
import System.PosixCompat.Files
import System.FilePath.Posix
import System.Directory
import qualified Data.Map.Strict as M
import Control.Concurrent.STM.TVar
import Control.Concurrent.STM
import Control.Exception.Base
import Control.Monad (when)
import HADFS.Types
import System.Fuse
import Data.Maybe
import Data.Either
import Data.List (isPrefixOf)
import Control.Monad
import Debug.Trace
#if MIN_VERSION_base(4,6,0)
import Control.Applicative
import Data.Semigroup ((<>))
#endif

type HT = ()
type FSMap = M.Map FilePath FileStat
type FSError = (Errno, String)

data ObjectCategory
  = Person
  | Default
  deriving (Eq, Show)

data AttrWriteMode = LdifMode
                   | JsonMode

noErr :: FSError
noErr = (eOK, "")

data State = State{ad   :: !ADCtx
                  ,logF :: !(String -> IO ())
                  ,lastError :: TVar FSError
                  ,tmp :: FilePath
                  }

instance Show (String -> IO()) where
  show _ = "logger"

--hadfsInit :: Realm -> Host -> Port -> FilePath -> FilePath -> Logger -> IO ()
hadfsInit :: String -> String -> Int -> FilePath -> FilePath -> Logger -> IO ()
hadfsInit domain host port mountpoint cacheDir logF = do
  ad <- adInit domain' host port
  errorState <- newTVarIO (eOK, "")
  let st = State ad putStrLn errorState cacheDir
      lePath = cacheDir </> ".lasterror"
      prog = "hadfs"
      host'' = T.unpack $ if T.isSuffixOf domain' host' then host' else host' <> "." <> domain'

  createDirectoryIfMissing False cacheDir
  writeFile (cacheDir </> ".dummy") ""
  writeFile lePath "bebebe"
  createDirectoryIfMissing False (cacheDir </> "CN=Configuration")
  createDirectoryIfMissing False (cacheDir </> "CN=Schema,CN=Configuration")

  fuseRun prog [mountpoint
               ,"-o", "default_permissions,auto_unmount"
               ,"-o", "subtype=" ++ host'', "-o", "fsname=" ++ prog
 --              ,"-o", "big_writes"
               ,"-f"
               ] (adFSOps st) (exceptionHandler errorState lePath)
  where domain' = T.pack domain
        host' = T.pack host

adFSOps :: State -> FuseOperations HT
adFSOps s = defaultFuseOps { fuseGetFileStat = getFileStat s
                           , fuseOpen        = openF s
                           , fuseRead        = readF s
                           , fuseOpenDirectory = openD s
                           , fuseReadDirectory = readD s
                           , fuseGetFileSystemStats = getFileSystemStats s
                           -- create operations
                           , fuseCreateDirectory = mkdir s
                           , fuseCreateDevice = create s
                           -- delete operations
                           , fuseRemoveLink = unlink s
                           , fuseRemoveDirectory = rmdir s
                           -- write operations
                           , fuseSetFileSize = setFSize s
                           , fuseWrite = write s
                           -- other
                           , fuseSetFileTimes = setFTime s
                           , fuseRename = mv s
                           , fuseInit = fInit s
                           }

fInit State{..} = do
  logF "FUSE loop started"

exceptionHandler :: TVar FSError -> FilePath -> (SomeException -> IO Errno)
exceptionHandler lerr lePath e = do
  atomically $ writeTVar lerr (eFAULT, show e)
  writeFile lePath (show e)
  putStrLn $ show e
  return eFAULT

getFileStat :: State -> FilePath -> IO (Either Errno FileStat)
getFileStat State{..} path | takeFileName path == ".refresh" = do
                               status <- getFileStatus (tmp </> ".dummy")
                               return $ Right $ fromStatus status
getFileStat st@State{..} path = do
  x <- doesPathExist cachePath
  when (not x) $ refresh st $ takeDirectory path
  x' <- doesPathExist cachePath
  if x' then do
    status <- getFileStatus cachePath
    return $ Right $ fromStatus status
  else return $ Left eNOENT
  where cachePath = tmp </> tail path

openD State{..} "/" = return eOK
openD State{..} path = do
  createDirectoryIfMissing True (tmp </> tail path)
  return eOK

refreshHooks :: State -> ObjectCategory -> FilePath -> IO ()
refreshHooks st@State{..} Person path = do
  refreshHooks st Default path
  exists <- doesFileExist (cachePath </> ".chpwd")
  when exists $ removeFile (cachePath </> ".chpwd")
  let hooks = [(cachePath </> ".chpwd", "")]
  mapM_ (uncurry createIfNotDeleted) hooks
  where cachePath = tmp </> tail path

refreshHooks st@State{..} Default path = do
--  ctx <- getFuseContext
--  attrs <- nodeAttrs ad path ["*", "+", "nTSecurityDescriptor"]
  res <- recordOf ad path
  case res of
    Left e -> error $ show e
    Right record -> do
      let hooks = [(cachePath </> ".attributes", T.unpack (unTagged $ toLdif [record]))
                  ,(cachePath </> ".attributes.json", T.unpack (toJsonPP record))
                  ] <> if path == "/" then [(cachePath </> ".lasterror", "")] else []
      mapM_ (uncurry createIfNotDeleted) hooks
        where cachePath = tmp </> tail path

createIfNotDeleted :: FilePath -> String -> IO ()
createIfNotDeleted path content = do
  exists <- fileExist ph
  if exists
    then return ()
    else writeFile path content
  where ph = takeDirectory path </> "." ++ fileName
        fileName = takeFileName path

refresh :: State -> FilePath -> IO ()
refresh st@State{..} path = do
  logF $ "refreshing: " ++ path
  oc <- nodeAttr ad (path2dn ad path) "objectCategory"
  case oc of
    [] -> return ()
    oc -> do
      chs <- childrenOf' ad path
      let nodes = map (T.unpack . rdnOf) chs
          objCat = toObjCat $ head oc
      mapM_ (\x -> createDirectoryIfMissing True (tmp </> tail path </> x)) nodes
      refreshHooks st objCat path

toObjCat :: Val -> ObjectCategory
toObjCat v = case v' of
  "CN=Person" -> Person
  _ -> Default
  where v' = BC.takeWhile (/=',') v

fromStatus :: FileStatus -> FileStat
fromStatus st =
  FileStat { statEntryType = entryType st
           , statFileMode = fileMode st
           , statLinkCount = linkCount st
           , statFileOwner = fileOwner st
           , statFileGroup = fileGroup st
           , statSpecialDeviceID = specialDeviceID st
           , statFileSize = fileSize st
           , statBlocks = 1
           , statAccessTime = accessTime st
           , statModificationTime = modificationTime st
           , statStatusChangeTime = statusChangeTime st
           }

entryType :: FileStatus -> EntryType
entryType m | isDirectory m = Directory
            | otherwise = RegularFile

readD :: State -> FilePath -> IO (Either Errno [(FilePath, FileStat)])
readD st@State{..} path = do
  ctx <- getFuseContext
  refresh st path
  content <- listDirectory (tmp </> tail path) >>= \x -> return $ filter (not . isPrefixOf "..") x
  stats <- mapM (\x -> fromStatus <$> getFileStatus (tmp </> tail path </> x)) content
  return $ Right $ zip content stats

openF :: State -> FilePath -> OpenMode -> OpenFileFlags -> IO (Either Errno HT)
openF State{..} path mode flags = return $ Right ()

readF :: State -> FilePath -> HT -> ByteCount -> FileOffset -> IO (Either Errno BS.ByteString)
readF st@State{..} path _ byteCount offset = do
  putStrLn $ "read file:" ++ path
  content <- BS.readFile (tmp </> tail path)
  return $ Right content

getFileSystemStats :: State -> String -> IO (Either Errno FileSystemStats)
getFileSystemStats State{..} str =
  return $ Right $ FileSystemStats
    { fsStatBlockSize = 512
    , fsStatBlockCount = 1
    , fsStatBlocksFree = 1
    , fsStatBlocksAvailable = 1
    , fsStatFileCount = 5
    , fsStatFilesFree = 10
    , fsStatMaxNameLength = 255
    }

unlink :: State -> FilePath -> IO Errno
unlink st@State{..} path = do
  renameFile cachePath newName
  return eOK
  where cachePath = tmp </> tail path
        newName = cacheDir </> "." ++ fileName
        cacheDir = takeDirectory cachePath
        fileName = takeFileName cachePath

rmdir :: State -> FilePath -> IO Errno
rmdir st@State{..} path = do
  delRec ad $ path2dn ad path
  removeDirectoryRecursive cachePath
  return eOK
  where cachePath = tmp </> tail path

cleanCacheDir :: State -> FilePath -> IO Errno
cleanCacheDir State{..} path = do
  let cacheDir = tmp </> tail (takeDirectory path)
  files <- listDirectory cacheDir
  mapM_ (\n -> removeFile (cacheDir </> n)) files
  return eOK

-- create operations
create :: State -> FilePath -> EntryType -> FileMode -> DeviceID -> IO Errno
create st@State{..} path RegularFile mode _ | takeFileName path == ".refresh" = cleanCacheDir st path
                                            | takeFileName path == ".attributes" || takeFileName path == ".attributes.json" = do
                                                let cacheDir = tmp </> tail (takeDirectory path)
                                                    cacheFile = cacheDir </> takeFileName path
                                                exists <- doesFileExist cacheFile
                                                if not exists
                                                  then do writeFile cacheFile ""
                                                          return eOK
                                                  else return eACCES
                                            | ".search" `isPrefixOf` takeFileName path = do
                                                let cacheDir = tmp </> tail (takeDirectory path)
                                                writeFile (cacheDir </> takeFileName path) ""
                                                return eOK
                                            | ".chpwd" == takeFileName path = do
                                                let cacheDir = tmp </> tail (takeDirectory path)
                                                writeFile (cacheDir </> takeFileName path) ""
                                                return eOK
                                            | otherwise = return eACCES

setFTime :: State -> FilePath -> EpochTime -> EpochTime -> IO Errno
setFTime st path _ _ | takeFileName path == ".refresh" = cleanCacheDir st path
                     | otherwise = return eOK

-- write operations
setFSize :: State -> FilePath -> FileOffset -> IO Errno
setFSize st@State{..} path offset | takeFileName path == ".refresh" = cleanCacheDir st path
                                  | otherwise = do
                                      return eOK

write :: State -> FilePath -> HT -> ByteString -> FileOffset -> IO (Either Errno ByteCount)
write st@State{..} path _ content offset | takeFileName path == ".attributes" = writeAttrs st path () content offset LdifMode
                                         | takeFileName path == ".attributes.json" = writeAttrs st path () content offset JsonMode
                                         | takeFileName path == ".refresh" = return $ Right $ fromIntegral $ BS.length content
                                         | takeFileName path == ".chpwd" = changeUserPassword st path () content offset
                                         | ".search" `isPrefixOf` takeFileName path = searchHandler st path () content offset
                                         | otherwise = return $ Left eNOSYS

changeUserPassword :: State -> FilePath -> HT -> ByteString -> FileOffset -> IO (Either Errno ByteCount)
changeUserPassword State{..} path _ content offset | content == BS.empty = do
                                                       return $ Right $ fromIntegral $ BS.length content
                                                   | otherwise = do
                                                       adSetUserPass ad (path2dn ad . takeDirectory $ path) (T.decodeUtf8 content)
                                                       return $ Right $ fromIntegral $ BS.length content

writeAttrs :: State -> FilePath -> HT -> ByteString -> FileOffset -> AttrWriteMode -> IO (Either Errno ByteCount)
writeAttrs st@State{..} path _ content offset mode = do
  oldCont <- BS.readFile cachePath

  let old = head $ toRecFunc oldCont
      new = head $ case offset of
                     0 -> toRecFunc content
                     x -> toRecFunc $ BS.take (fromIntegral offset) oldCont <> content <> BS.drop (fromIntegral offset + contentLength) oldCont
      contentLength = fromIntegral $ BS.length content
      modOps = cmp ad old new
  if oldCont == BS.empty
    then newRec ad $ new {dn = path2dn ad nodePath}
    else modRec ad modOps
  refresh st nodePath
  return $ Right $ fromIntegral $ BS.length content
  where cachePath = tmp </> tail path
        nodePath = tmp </> takeDirectory path
        toRecFunc = case mode of
                      LdifMode -> fromLdifBS ad
                      JsonMode -> (:[]) . fromJson . T.decodeUtf8

mkdir :: State -> FilePath -> FileMode -> IO Errno
mkdir st@State{..} path mode = do
  createDirectoryIfMissing True (tmp </> tail path)
  return eOK

searchHandler :: State -> FilePath -> HT -> ByteString -> FileOffset -> IO (Either Errno ByteCount)
searchHandler st@State{..} path _ content offset = do
  res <- adSearchReq ad dn' (T.decodeUtf8 content)
  let searchRes = toLdifBS res
      searchResJson = T.encodeUtf8 $ T.unlines $ map toJson res
  BS.writeFile cachePath content
  BS.writeFile (cachePath <.> ".result") searchRes
  BS.writeFile (cachePath <.> ".result.json") searchResJson
  return $ Right $ fromIntegral $ BS.length content
  where cacheDir = tmp </> tail (takeDirectory path)
        cachePath = cacheDir </> takeFileName path
        dn' = path2dn ad . takeDirectory $ path

mv :: State -> FilePath -> FilePath -> IO Errno
mv State{..} from to = do
  movRec ad f t
  removeDirectoryRecursive cacheDir
  return eOK
  where cacheDir = tmp </> tail from
        f = path2dn ad from
        t = path2dn ad to
