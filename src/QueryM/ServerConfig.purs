module QueryM.ServerConfig
  ( Host
  , ServerConfig
  , defaultServerConfig
  , defaultOgmiosWsConfig
  , defaultDatumCacheWsConfig
  , mkHttpUrl
  , mkWsUrl
  , mkOgmiosDatumCacheWsUrl
  , mkServerUrl
  ) where

import Prelude

import Data.Maybe (maybe, Maybe(Nothing))
import Data.UInt (UInt)
import Data.UInt as UInt
import JsWebSocket (Url)

type Host = String

type ServerConfig =
  { port :: UInt
  , host :: Host
  , secure :: Boolean
  , path :: Maybe String
  }

defaultServerConfig :: ServerConfig
defaultServerConfig =
  { port: UInt.fromInt 8081
  , host: "localhost"
  , secure: false
  , path: Nothing
  }

defaultOgmiosWsConfig :: ServerConfig
defaultOgmiosWsConfig =
  { port: UInt.fromInt 1337
  , host: "localhost"
  , secure: false
  , path: Nothing
  }

defaultDatumCacheWsConfig :: ServerConfig
defaultDatumCacheWsConfig =
  { port: UInt.fromInt 9999
  , host: "localhost"
  , secure: false
  , path: Nothing
  }

mkHttpUrl :: ServerConfig -> Url
mkHttpUrl = mkServerUrl "http"

mkWsUrl :: ServerConfig -> Url
mkWsUrl = mkServerUrl "ws"

mkOgmiosDatumCacheWsUrl :: ServerConfig -> Url
mkOgmiosDatumCacheWsUrl cfg = mkWsUrl cfg <> "/ws"

mkServerUrl :: String -> ServerConfig -> Url
mkServerUrl protocol cfg =
  (if cfg.secure then (protocol <> "s") else protocol)
    <> "://"
    <> cfg.host
    <> ":"
    <> UInt.toString cfg.port
    <> maybe "" ("/" <> _) cfg.path
