{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE TemplateHaskell #-}

module Types.Posts where

import           Cheapskate (Blocks)
import qualified Cheapskate as C
import qualified Data.Map.Strict as Map
import           Data.Monoid ((<>))
import qualified Data.Sequence as Seq
import qualified Data.Text as T
import           Data.Time.Clock (UTCTime)
import           Lens.Micro.Platform ((^.), makeLenses)
import           Network.Mattermost
import           Network.Mattermost.Lenses

-- * Client Messages

-- | A 'ClientMessage' is a message given to us by our client,
--   like help text or an error message.
data ClientMessage = ClientMessage
  { _cmText :: T.Text
  , _cmDate :: UTCTime
  , _cmType :: ClientMessageType
  } deriving (Eq, Show)

-- | We format 'ClientMessage' values differently depending on
--   their 'ClientMessageType'
data ClientMessageType =
    Informative
    | Error
    | DateTransition
    | NewMessagesTransition
    deriving (Eq, Show)

-- ** 'ClientMessage' Lenses

makeLenses ''ClientMessage

-- * Mattermost Posts

-- | A 'ClientPost' is a temporary internal representation of
--   the Mattermost 'Post' type, with unnecessary information
--   removed and some preprocessing done.
data ClientPost = ClientPost
  { _cpText          :: Blocks
  , _cpUser          :: Maybe UserId
  , _cpUserOverride  :: Maybe T.Text
  , _cpDate          :: UTCTime
  , _cpType          :: ClientPostType
  , _cpPending       :: Bool
  , _cpDeleted       :: Bool
  , _cpAttachments   :: Seq.Seq Attachment
  , _cpInReplyToPost :: Maybe PostId
  , _cpPostId        :: PostId
  , _cpChannelId     :: ChannelId
  , _cpReactions     :: Map.Map T.Text Int
  , _cpOriginalPost  :: Post
  } deriving (Show)

-- | An attachment has a very long URL associated, as well as
--   an actual file URL
data Attachment = Attachment
  { _attachmentName   :: T.Text
  , _attachmentURL    :: T.Text
  , _attachmentFileId :: FileId
  } deriving (Eq, Show)

-- | A Mattermost 'Post' value can represent either a normal
--   chat message or one of several special events.
data ClientPostType =
    NormalPost
    | Emote
    | Join
    | Leave
    | TopicChange
    deriving (Eq, Show)

-- ** Creating 'ClientPost' Values

-- | Parse text as Markdown and extract the AST
getBlocks :: T.Text -> Blocks
getBlocks s = bs where C.Doc _ bs = C.markdown C.def s

-- | Determine the internal 'PostType' based on a 'Post'
postClientPostType :: Post -> ClientPostType
postClientPostType cp =
    if | postIsEmote cp       -> Emote
       | postIsJoin  cp       -> Join
       | postIsLeave cp       -> Leave
       | postIsTopicChange cp -> TopicChange
       | otherwise            -> NormalPost

-- | Find out whether a 'Post' represents a topic change
postIsTopicChange :: Post -> Bool
postIsTopicChange p = postType p == PostTypeHeaderChange

-- | Find out whether a 'Post' is from a @/me@ command
postIsEmote :: Post -> Bool
postIsEmote p =
    and [ p^.postPropsL.postPropsOverrideIconUrlL == Just (""::T.Text)
        , ("*" `T.isPrefixOf` postMessage p)
        , ("*" `T.isSuffixOf` postMessage p)
        ]

-- | Find out whether a 'Post' is a user joining a channel
postIsJoin :: Post -> Bool
postIsJoin p =
  p^.postTypeL == PostTypeJoinChannel

-- | Find out whether a 'Post' is a user leaving a channel
postIsLeave :: Post -> Bool
postIsLeave p =
  p^.postTypeL == PostTypeLeaveChannel

-- | Undo the automatic formatting of posts generated by @/me@-commands
unEmote :: ClientPostType -> T.Text -> T.Text
unEmote Emote t = if "*" `T.isPrefixOf` t && "*" `T.isSuffixOf` t
                  then T.init $ T.tail t
                  else t
unEmote _ t = t

-- | Convert a Mattermost 'Post' to a 'ClientPost', passing in a
--   'ParentId' if it has a known one.
toClientPost :: Post -> Maybe PostId -> ClientPost
toClientPost p parentId = ClientPost
  { _cpText          = (getBlocks $ unEmote (postClientPostType p) $ postMessage p)
                       <> getAttachmentText p
  , _cpUser          = postUserId p
  , _cpUserOverride  = p^.postPropsL.postPropsOverrideUsernameL
  , _cpDate          = postCreateAt p
  , _cpType          = postClientPostType p
  , _cpPending       = False
  , _cpDeleted       = False
  , _cpAttachments   = Seq.empty
  , _cpInReplyToPost = parentId
  , _cpPostId        = p^.postIdL
  , _cpChannelId     = p^.postChannelIdL
  , _cpReactions     = Map.empty
  , _cpOriginalPost  = p
  }

-- | Right now, instead of treating 'attachment' properties specially, we're
--   just going to roll them directly into the message text
getAttachmentText :: Post -> Blocks
getAttachmentText p =
  case p^.postPropsL.postPropsAttachmentsL of
    Nothing -> Seq.empty
    Just attachments ->
      fmap (C.Blockquote . render) attachments
  where render att = getBlocks (att^.ppaTextL) <> getBlocks (att^.ppaFallbackL)

-- ** 'ClientPost' Lenses

makeLenses ''Attachment
makeLenses ''ClientPost
