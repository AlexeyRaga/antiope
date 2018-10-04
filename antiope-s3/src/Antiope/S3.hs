{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}

module Antiope.S3
( s3ObjectSource
, putFile, putContent , putContent'
, copySingle
, fromS3Uri
, toS3Uri
, lsBucketResponseStream
, lsBucketStream
, Region(..)
, BucketName(..)
, ObjectKey(..)
, ETag(..)
, S3Uri(..)
) where

import Antiope.S3.Internal
import Antiope.S3.Types             (S3Uri (S3Uri))
import Control.Lens
import Control.Monad
import Control.Monad.Trans.AWS      hiding (send)
import Control.Monad.Trans.Resource
import Data.Conduit
import Data.Conduit.Combinators     as CC (concatMap)
import Data.Conduit.List            (unfoldM)
import Data.Monoid                  ((<>))
import Data.Text                    as T (Text, pack, unpack)
import Network.AWS                  (MonadAWS)
import Network.AWS.Data
import Network.AWS.Data.Body        (_streamBody)
import Network.AWS.S3
import Network.URI                  (URI (..), URIAuth (..), parseURI, unEscapeString)

import qualified Data.ByteString      as BS
import qualified Data.ByteString.Lazy as LBS
import qualified Network.AWS          as AWS

chunkSize :: ChunkSize
chunkSize = ChunkSize (1024 * 1024)

fromS3Uri :: Text -> Maybe S3Uri
fromS3Uri uri = do
  puri <- parseURI (unpack uri)
  auth <- puri & uriAuthority
  let b = pack $ auth & uriRegName       -- URI lib is pretty weird
  let k = pack $ unEscapeString $ drop 1 $ puri & uriPath
  pure $ S3Uri (BucketName b) (ObjectKey k)

s3ObjectSource :: (MonadAWS m, MonadResource m)
  => BucketName
  -> ObjectKey
  -> m (ConduitT () BS.ByteString m ())
s3ObjectSource bkt obj = do
  resp <- AWS.send $ getObject bkt obj
  return $ transPipe liftResourceT $ _streamBody $ resp ^. gorsBody

-- | Puts file into a specified S3 bucket
putFile :: MonadAWS m
  => BucketName       -- ^ Target bucket
  -> ObjectKey        -- ^ File name on S3
  -> FilePath         -- ^ Source file path
  -> m (Maybe ETag)   -- ^ Etag when the operation is successful
putFile b k f = do
    req <- chunkedFile chunkSize f
    view porsETag <$> AWS.send (putObject b k req)

putContent :: MonadAWS m
  => BucketName
  -> ObjectKey
  -> LBS.ByteString
  -> m (Maybe ETag)
putContent b k c = view porsETag <$> AWS.send (putObject b k (toBody c))

putContent' :: MonadAWS m
  => S3Uri
  -> LBS.ByteString
  -> m (Maybe ETag)
putContent' (S3Uri b k) = putContent b k

-- | Copies a single object within S3
copySingle :: MonadAWS m
  => BucketName          -- ^ Source bucket name
  -> ObjectKey           -- ^ Source key
  -> BucketName          -- ^ Target bucket name
  -> ObjectKey           -- ^ Target key
  -> m ()
copySingle sb sk tb tk = void . AWS.send $ copyObject tb (toText sb <> "/" <> toText sk) tk
     & coMetadataDirective ?~ MDCopy

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
  resp <- AWS.send req
  pure . Just . (resp, ) $
    case resp ^. lovrsIsTruncated of
      Just True -> Just $ nextPageReq req resp
      _         -> Nothing

-- | Streams all pages of the result (ListObjectsV2Responses) of a ListObjectsV2
-- request from S3.
-- lsBucketResponseStream :: MonadAWS m => ListObjectsV2 -> ConduitT i ListObjectsV2Response m ()
lsBucketResponseStream :: MonadAWS m
  => ListObjectsV2
  -> ConduitM a ListObjectsV2Response m ()
lsBucketResponseStream bar = unfoldM lsBucketPage (Just bar)

-- | Streams all Objects from all pages of the result of a ListObjectsV2
-- request from S3.
-- lsBucketStream :: MonadAWS m => ListObjectsV2 -> ConduitT i Object m ()
lsBucketStream :: MonadAWS m
  => ListObjectsV2
  -> ConduitM a Object m ()
lsBucketStream bar = lsBucketResponseStream bar .| CC.concatMap (^. lovrsContents)
