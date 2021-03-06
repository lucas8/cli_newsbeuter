{-# LANGUAGE FlexibleContexts #-}
module Main where

import Text.XML.Light
import Text.Feed.Import
import Text.Feed.Query
import System.Environment
import System.Directory
import System.Process
import System.Exit
import Database.HDBC
import Database.HDBC.Sqlite3 (connectSqlite3)
import Data.Convertible.Base
import Data.Convertible (convert)
import Data.Time.Clock (UTCTime (..))
import Data.List.Split
import Data.Maybe
import Data.List
import Control.Exception

-- Data --------------------------------------------------------------
data RSSItem = RSSItem { it_title       :: Maybe String
                       , it_url         :: Maybe String
                       , it_feed_url    :: Maybe String
                       , it_description :: Maybe String
                       , it_author      :: Maybe String
                       , it_guid        :: Maybe String
                       , it_pubDate     :: Maybe Integer
                       , it_enc_url     :: Maybe String
                       , it_enc_type    :: Maybe String
                       , it_id          :: Maybe Integer
                       , it_unread      :: Maybe Bool
                       } deriving (Show)
data FDType  = Plain | Filter | Exec
data RSSFeed = RSSFeed { fd_rssurl :: Maybe String
                       , fd_url    :: Maybe String
                       , fd_title  :: Maybe String
                       , fd_type   :: Maybe FDType
                       , fd_tags   :: Maybe [String]
                       } deriving (Show)

-- Data classes
showFDType :: FDType -> String
showFDType Plain  = "Plain"
showFDType Filter = "Filter"
showFDType Exec   = "Exec"
instance Show FDType where
    show = showFDType

-- Database Querying -------------------------------------------------
rowToFeed :: [SqlValue] -> RSSFeed
rowToFeed (r:u:t:[]) = RSSFeed (Just $ fromSql r) (Just $ fromSql u) (Just $ fromSql t) Nothing Nothing
rowToFeed _          = RSSFeed Nothing Nothing Nothing Nothing Nothing

loadFeeds :: (IConnection c) => c -> IO [RSSFeed]
loadFeeds conn = do rows <- quickQuery' conn "SELECT rssurl,url,title FROM rss_feed" []
                    return $ map rowToFeed rows

hasFeed :: (IConnection c) => c -> RSSFeed -> IO Bool
hasFeed _    (RSSFeed Nothing _ _ _ _) = return False
hasFeed conn (RSSFeed rssurl  _ _ _ _) = do lst <- quickQuery' conn "SELECT rssurl FROM rss_feed WHERE rssurl = ?" [toSql rssurl]
                                            return (length lst /= 0)

populateFeed :: (IConnection c) => c -> RSSFeed -> IO RSSFeed
populateFeed conn fd = do query <- quickQuery' conn "SELECT rssurl,url,title FROM rss_feed WHERE rssurl = ?" [rurl]
                          return $ mergeTwo fd $ rowToFeed $ head query
    where rurl       = toSql $ fd_rssurl fd
          mergeTwo :: RSSFeed -> RSSFeed -> RSSFeed
          mergeTwo (RSSFeed rss _ _ _ tgs) (RSSFeed _ u t _ _) = RSSFeed rss u t Nothing tgs

findByGuid :: (IConnection c) => c -> RSSItem -> IO Bool
findByGuid conn (RSSItem _ _ _ _ _ (Just g) _ _ _ _ _) =
        do query <- quickQuery' conn "SELECT guid FROM rss_item WHERE guid = ?" [toSql g]
           return $ length query /= 0
findByGuid _ _ = return False

rowToItem :: [SqlValue] -> RSSItem
rowToItem (t:u:f:a:g:p:eu:et:id:ur:[]) = RSSItem (mfsql t)  (mfsql u)  (mfsql f)
                                               Nothing    (mfsql a)  (mfsql g)
                                               (mfsql p)  (mfsql eu) (mfsql et)
                                               (mfsql id) (bfsql ur)
    where mfsql :: (Convertible SqlValue a) => SqlValue -> Maybe a
          mfsql v = Just $ fromSql v
          bfsql :: SqlValue -> Maybe Bool
          bfsql v = Just $ intToBool $ fromSql v
              where intToBool :: Int -> Bool
                    intToBool 0 = False
                    intToBool _ = True

readItem :: (IConnection c) => c -> RSSItem -> IO RSSItem
readItem conn it@(RSSItem t u f d a (Just g) p eu et id ur) =
        do query <- quickQuery' conn "SELECT title,url,feedurl,author,guid,pubDate,enclosure_url,enclosure_type,id,unread FROM rss_item WHERE guid = ?" [toSql g]
           if query == [] then return it
           else return $ rowToItem $ head query
readItem conn it = return it

loadFeedItems :: (IConnection c) => c -> RSSFeed -> IO [RSSItem]
loadFeedItems _ (RSSFeed Nothing _ _ _ _) = return []
loadFeedItems conn fd = do query <- quickQuery' conn "SELECT title,url,feedurl,author,guid,pubDate,enclosure_url,enclosure_type,id,unread FROM rss_item WHERE feedurl = ?" [url]
                           return $ map rowToItem query
    where url = toSql $ fd_rssurl fd

-- Database writing (caller must call commit itself) -----------------
addFeed :: (IConnection c) => c -> RSSFeed -> IO ()
addFeed conn fd = do insert_if conn r
                     updateFeed conn fd
    where r = fd_rssurl fd
          insert_if c (Just r) = do run c "INSERT INTO rss_feed (rssurl,url,title) VALUES (?,'','')" [toSql r]
                                    return ()
          insert_if _ Nothing = return()

updateFeed :: (IConnection c) => c -> RSSFeed -> IO()
updateFeed _ (RSSFeed Nothing _ _ _ _) = return()
updateFeed c (RSSFeed r       u t _ _) = do update_if c r u "url"
                                            update_if c r t "title"
    where update_if _ _ Nothing _ = return()
          update_if c (Just r) (Just v) s = do run c ("UPDATE rss_feed SET " ++ s ++ " = ? WHERE rssurl = ?") [toSql v, toSql r]
                                               return()

addItem :: (IConnection c) => c -> RSSItem -> IO()
addItem conn it = do x <- quickQuery' conn "SELECT MAX(id) FROM rss_item" []
                     run conn "INSERT INTO rss_item (guid,title,author,url,feedurl,pubDate,content,unread,enclosure_url,enclosure_type) VALUES ('','','','','',0,'',1,'','')" []
                     updateItem conn $ setId it $ (pop x) + 1
    where pop :: [[SqlValue]] -> Integer
          pop x = fromSql $ head $ head x
          setId (RSSItem t u f d a g p eu et _ ur) id = RSSItem t u f d a g p eu et (Just id) ur

updateItem :: (IConnection c) => c -> RSSItem -> IO()
updateItem _ (RSSItem _ _ _ _ _ _ _ _  _  Nothing _)   = return()
updateItem c (RSSItem t u f d a g p eu et id      urd) = do update_if c t  id "title"
                                                            update_if c u  id "url"
                                                            update_if c f  id "feedurl"
                                                            update_if c d  id "content"
                                                            update_if c a  id "author"
                                                            update_if c g  id "guid"
                                                            update_if c p  id "pubDate"
                                                            update_if c eu id "enclosure_url"
                                                            update_if c et id "enclosure_type"
                                                            update_if c ur id "unread"
    where ur = bti urd
          update_if _ Nothing   _        _ = return()
          update_if c (Just v) (Just id) s = do run c ("UPDATE rss_item SET " ++ s ++ " = ? WHERE id = ?") [toSql v, toSql id]
                                                return()
          bti :: Maybe Bool -> Maybe Int
          bti Nothing      = Nothing
          bti (Just True)  = Just 1
          bti (Just False) = Just 0

-- Load RSSFeeds from url file ---------------------------------------
cutLine :: String -> String -> Bool -> [String]
cutLine ""       ""    _     = []
cutLine ""       chunk _     = [chunk]
cutLine ('"':ls) ""    True  = cutLine ls "" False
cutLine ('"':ls) chunk True  = chunk : cutLine ls "" False
cutLine (l:ls)   chunk True  = cutLine ls (chunk ++ [l]) True
cutLine ('"':ls) ""    False = cutLine ls "" True
cutLine ('"':ls) chunk False = chunk:cutLine ls "" True
cutLine (l:ls)   chunk False
     | isBlank l = if chunk == "" then cutLine ls "" False
                   else chunk : cutLine ls "" False
     | otherwise = cutLine ls (chunk ++ [l]) False
    where isBlank ' '  = True
          isBlank '\t' = True
          isBlank '\n' = True
          isBlank  _   = False

loadFeedsFromFile :: FilePath -> IO [RSSFeed]
loadFeedsFromFile ""   = return []
loadFeedsFromFile path = do file <- readFile path
                            return $ rmNothing $ map parseLine $ lines file
    where rmNothing :: [Maybe RSSFeed] -> [RSSFeed]
          rmNothing  []           = []
          rmNothing (Nothing:rs)  = rmNothing rs
          rmNothing ((Just r):rs) = r:rmNothing rs
          parseLine :: String -> Maybe RSSFeed
          parseLine str
               | parts == [] = Nothing
               | otherwise   = Just $ RSSFeed (Just $ head parts) Nothing Nothing Nothing (Just $ tail parts)
              where parts = cutLine str "" False

-- Initialisation of data --------------------------------------------
newFeeds :: (IConnection c) => c -> [RSSFeed] -> IO [RSSFeed]
newFeeds _ [] = return []
newFeeds conn (l:ls) = do b <- hasFeed conn l
                          if b then newFeeds conn ls
                          else do nfds <- newFeeds conn ls
                                  return $ l : nfds

addNewFeed :: (IConnection c) => c -> RSSFeed -> IO()
addNewFeed conn fd = addFeed conn toadd
    where toadd = setTitle fd $ fd_rssurl fd
          setTitle :: RSSFeed -> Maybe String -> RSSFeed
          setTitle (RSSFeed r u _ ty tgs) title = RSSFeed r u title ty tgs

-- TODO Find right type for this function
initing urls db = do conn <- connectSqlite3 db
                     ufds <- loadFeedsFromFile urls
                     nfds <- newFeeds conn ufds
                     mapM_ (addNewFeed conn) nfds
                     commit conn
                     fds <- mapM (populateFeed conn) ufds
                     return (conn, fds)

-- Feed manipulation -------------------------------------------------
findType :: RSSFeed -> Maybe FDType
findType (RSSFeed Nothing    _ _ _ _) = Nothing
findType (RSSFeed (Just url) _ _ _ _) = Just $ typeFromUrl url
    where typeFromUrl :: String -> FDType
          typeFromUrl ('f':'i':'l':'t':'e':'r':_) = Filter
          typeFromUrl ('e':'x':'e':'c':_)         = Exec
          typeFromUrl _                           = Plain

setType :: RSSFeed -> RSSFeed
setType fd@(RSSFeed r u t _ tgs) = RSSFeed r u t tpe tgs
    where tpe = findType fd

parseFilter :: String -> (String,[String],String)
parseFilter str
     | id /= "filter" || fl == "" || url == "" = ("", [], "")
     | otherwise = (head flct, tail flct, url)
    where parts        = splitOn ":" str
          (id:fl:urls) = parts
          url          = intercalate ":" urls
          flct         = splitOn " " fl

parseExec :: String -> (String,[String])
parseExec str
     | length parts /= 2 || id /= "exec" || ex == "" = ("", [])
     | otherwise = (head exct, tail exct)
    where parts      = splitOn ":" str
          (id:ex:[]) = parts
          exct       = splitOn " " ex

-- Downloading a feed ------------------------------------------------
adapt :: (ExitCode, String, String) -> IO (Maybe String)
adapt (ExitFailure _, _, _) = return Nothing
adapt (ExitSuccess, out, _) = return $ Just out

dlUrl :: String -> IO (Maybe String)
dlUrl url = readProcessWithExitCode cmd args "" >>= adapt
    where cmd  = "/usr/bin/curl"
          args = [url]

dlFilter :: String -> [String] -> String -> IO (Maybe String)
dlFilter cmd args input = readProcessWithExitCode cmd args input >>= adapt

dlExec :: String -> [String] -> IO (Maybe String)
dlExec cmd args = dlFilter cmd args ""

download :: RSSFeed -> IO (Maybe String)
download (RSSFeed (Just url) _ _ (Just Plain)  _) = dlUrl url
download (RSSFeed (Just ul)  _ _ (Just Filter) _) = do dl <- dlUrl url
                                                       if isNothing dl then return Nothing
                                                       else let (Just s) = dl in dlFilter c a s
    where (c,a,url) = parseFilter ul
download (RSSFeed (Just url) _ _ (Just Exec)   _) = dlExec cmd args
    where (cmd,args) = parseExec url
download fd@(RSSFeed (Just _) _ _ Nothing      _) = download $ setType fd
download _                                        = return Nothing

-- Parsing xml feed --------------------------------------------------
parseFeed :: RSSFeed -> String -> Maybe (RSSFeed, [RSSItem])
parseFeed fd xml
     | isNothing psfd = Nothing
     | otherwise      = Just (setTitle fd $ getFeedTitle feed, map parseItem $ feedItems feed)
    where psfd        = parseFeedString xml
          (Just feed) = psfd
          setTitle :: RSSFeed -> String -> RSSFeed
          setTitle (RSSFeed r u _ tp tg) t = RSSFeed r u (Just t) tp tg

parseItem v = RSSItem (getItemTitle       v)
                      (getItemLink        v)
                      Nothing
                      (getItemDescription v)
                      (getItemAuthor      v)
                      (getItemId v >>= (\(_,g) -> Just g))
                      (getItemPublishDate v >>= (>>= Just . utcTimeToEpochTime))
                      (getItemEnclosure v >>= (\(e,_,_) -> Just e))
                      (getItemEnclosure v >>= (\(_,e,_) -> e))
                      Nothing
                      Nothing
    where utcTimeToEpochTime :: UTCTime -> Integer
          utcTimeToEpochTime = convert

-- Updating a feed ---------------------------------------------------
dlUpdateFeed :: (IConnection c) => c -> RSSFeed -> IO [RSSItem]
dlUpdateFeed conn fd = do dlxml <- download fd
                          let psfd = dlxml >>= parseFeed fd
                          if isNothing psfd then return []
                          else let (Just (feed,its)) = psfd in upgradeFeed conn 
                                                                           feed
                                                                           $ map (prep feed) its
    where prep :: RSSFeed -> RSSItem -> RSSItem
          prep fd@(RSSFeed r@(Just _) _ _ _ _) (RSSItem t u Nothing d a g p eu et id ur) = prep fd $ RSSItem t u r d a g p eu et id ur
          prep fd (RSSItem t u@(Just _) r d a Nothing p eu et id ur) = prep fd $ RSSItem t u r d a u p eu et id ur
          prep fd (RSSItem t u r d a g p eu et id Nothing) = prep fd $ RSSItem t u r d a g p eu et id (Just False)
          prep _ it = it

upgradeFeed :: (IConnection c) => c -> RSSFeed -> [RSSItem] -> IO [RSSItem]
upgradeFeed conn _ its = mapM (procFDItem conn) its
    where procFDItem :: (IConnection c) => c -> RSSItem -> IO RSSItem
          procFDItem conn it = do b <- findByGuid conn it
                                  if b then readItem conn it
                                  else do addItem conn it
                                          return it

-- Get the paths -----------------------------------------------------
safeGetEnv :: String -> IO (Maybe String)
safeGetEnv var = handle mcatch $ menv var
   where mcatch :: IOError -> IO (Maybe String)
         mcatch _ = return Nothing
         menv :: String -> IO (Maybe String)
         menv var = do val <- getEnv var
                       return $ Just val

firstNotNothing :: [Maybe a] -> a -> a
firstNotNothing []            d = d
firstNotNothing (Nothing:ls)  d = firstNotNothing ls d
firstNotNothing ((Just v):ls) _ = v

getVar :: String -> String -> IO (Maybe String)
getVar var end = do home <- safeGetEnv var
                    mgetHome ('/':end) home
    where mgetHome :: String -> Maybe String -> IO (Maybe String)
          mgetHome _   Nothing  = return Nothing
          mgetHome end (Just h) = return $ Just $ h ++ end

getArg :: [String] -> String -> Maybe String
getArg (('-':'-':ag):v:vs) nm
     | ag == nm  = Just v
     | otherwise = getArg (v:vs) nm
getArg (_:ags) nm = getArg ags nm
getArg [] _ = Nothing

getDefaultDir :: [String] -> IO String
getDefaultDir args = do vals <- sequence $ sup:def:env:xdg:[]
                        return $ firstNotNothing vals "."
    where env = getVar "XDG_DATA_HOME" "newsbeuter"
          xdg = getVar "HOME" ".local/share/newsbeuter" >>= exists
          def = getVar "HOME" ".newsbeuter" >>= exists
          sup = return $ getArg args "dir"
          exists :: Maybe String -> IO (Maybe String)
          exists Nothing  = return Nothing
          exists (Just p) = do b <- doesDirectoryExist p
                               if b then return $ Just p 
                               else return Nothing

-- Main process ------------------------------------------------------
main :: IO()
main = do args  <- getArgs
          dir   <- getDefaultDir args
          let urls = dir ++ "/urls"
          let cache = dir ++ "/cache.db"
          (conn, feeds) <- initing urls cache
          mapM_ (\x -> let (Just t) = fd_title x in putStrLn t) feeds
          disconnect conn

