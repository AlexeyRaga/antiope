{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}

module Antiope.S3
( downloadLBS
, downloadLBS'
, s3ObjectSource
, putFile, putContent
, copySingle
, fromS3Uri
, toS3Uri
, lsBucketStream
, Region(..)
, BucketName(..)
, ObjectKey(..)
, ETag(..)
, S3Uri(..)
, MonadAWS
, MonadResource
, FromText(..), fromText
, ToText(..)
, module Network.AWS.S3
) where

import Control.Lens
import Control.Monad
import Control.Monad.Catch          (catch)
import Control.Monad.IO.Class       (liftIO)
import Control.Monad.Morph          (hoist)
import Control.Monad.Trans.AWS      hiding (send)
import Control.Monad.Trans.Resource
import Data.ByteString.Lazy         (ByteString, empty)
import Data.Conduit
import Data.Conduit.Binary          (sinkLbs)
import Data.Conduit.Combinators     as CC (concatMap)
import Data.Conduit.List            (unfoldM)
import Data.Monoid                  ((<>))
import Data.Text                    (Text, pack, unpack)
import Network.AWS                  (Error (..), MonadAWS, ServiceError (..), send)
import Network.AWS.Data
import Network.AWS.Data.Body        (_streamBody)
import Network.AWS.S3
import Network.HTTP.Types.Status    (Status (..))
import Network.URI                  (URI (..), URIAuth (..), parseURI)

import qualified Data.ByteString as BS

chunkSize :: ChunkSize
chunkSize = ChunkSize (1024*1024)

data S3Uri = S3Uri
  { s3Bucket    :: BucketName
  , s3ObjectKey :: ObjectKey
  } deriving (Show, Eq)

instance ToText S3Uri where
  toText loc = toS3Uri (s3Bucket loc) (s3ObjectKey loc)

toS3Uri :: BucketName -> ObjectKey -> Text
toS3Uri (BucketName b) (ObjectKey k) =
  "s3://" <> b <> "/" <> k

fromS3Uri :: Text -> Maybe S3Uri
fromS3Uri uri = do
  puri <- parseURI (unpack uri)
  auth <- puri & uriAuthority
  let b = pack $ auth & uriRegName       -- URI lib is pretty weird
  let k = pack $ drop 1 $ puri & uriPath
  pure $ S3Uri (BucketName b) (ObjectKey k)

downloadLBS :: (MonadResource m, MonadAWS m)
            => BucketName
            -> ObjectKey
            -> m ByteString
downloadLBS bucketName objectKey = do
  resp <- send $ getObject bucketName objectKey
  (resp ^. gorsBody) `sinkBody` sinkLbs

downloadLBS' :: (MonadResource m, MonadAWS m)
            => BucketName
            -> ObjectKey
            -> m (Maybe ByteString)
downloadLBS' bucketName objectKey = do
  ebs <- (Right <$> downloadLBS bucketName objectKey) `catch` \(e :: Error) -> case e of
    (ServiceError (ServiceError' _ (Status 404 _) _ _ _ _)) -> return (Left empty)
    _                                                       -> throwM e
  case ebs of
    Right bs -> return (Just bs)
    Left _   -> return Nothing

downloadS3File' :: (MonadResource m, MonadAWS m)
             => BucketName
             -> ObjectKey
             -> m (ConduitT () BS.ByteString m ())
downloadS3File' bkt obj = do
  resp <- send $ getObject bkt obj
  return $ transPipe liftResourceT $ _streamBody $ resp ^. gorsBody

s3ObjectSource :: (MonadResource m, MonadAWS m)
                 => BucketName
                 -> ObjectKey
                 -> m (ConduitT () BS.ByteString m ())
s3ObjectSource bkt obj = downloadS3File' bkt obj

-- | Puts file into a specified S3 bucket
putFile :: MonadAWS m
        => BucketName       -- ^ Target bucket
        -> ObjectKey        -- ^ File name on S3
        -> FilePath         -- ^ Source file path
        -> m (Maybe ETag)   -- ^ Etag when the operation is successful
putFile b k f = do
    req <- chunkedFile chunkSize f
    view porsETag <$> send (putObject b k req)

putContent :: MonadAWS m
           => BucketName
           -> ObjectKey
           -> ByteString
           -> m (Maybe ETag)
putContent b k c =
  view porsETag <$> send (putObject b k (toBody c))

-- | Copies a single object within S3
copySingle :: MonadAWS m
           => BucketName          -- ^ Source bucket name
           -> ObjectKey           -- ^ Source key
           -> BucketName          -- ^ Target bucket name
           -> ObjectKey           -- ^ Target key
           -> m ()
copySingle sb sk tb tk =
  void . send $ copyObject tb (toText sb <> "/" <> toText sk) tk
     & coMetadataDirective ?~ MDCopy

-- | Streams the entire set of results (i.e. all pages) of a ListObjectsV2
-- request from S3.
lsBucketStream :: MonadAWS m => ListObjectsV2 -> ConduitT i Object m ()
lsBucketStream bar = unfoldM lsBucketPage (Just bar) .| CC.concatMap (^. lovrsContents)

-- Private --

-- Builds the request for the next page of a NextObjectsV2 request,
-- based on the original request and the most recent response.
nextPageReq :: ListObjectsV2 -> ListObjectsV2Response -> ListObjectsV2
nextPageReq initial resp =
  initial & lovContinuationToken .~ resp ^. lovrsNextContinuationToken

-- The type signature is like this so that it can be used with `unfoldM`
lsBucketPage :: MonadAWS m
             => Maybe ListObjectsV2
             -> m (Maybe (ListObjectsV2Response, Maybe ListObjectsV2))
lsBucketPage Nothing    = pure Nothing
lsBucketPage (Just req) = do
  resp <- send req
  pure . Just . (resp, ) $
    case resp ^. lovrsIsTruncated of
      Just True -> Just $ nextPageReq req resp
      _         -> Nothing
