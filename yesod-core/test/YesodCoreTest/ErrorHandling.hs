{-# LANGUAGE TypeFamilies, QuasiQuotes, TemplateHaskell, MultiParamTypeClasses, OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module YesodCoreTest.ErrorHandling
    ( errorHandlingTest
    , Widget
    ) where
import Yesod.Core
import Test.Hspec
import Network.Wai
import Network.Wai.Test
import Text.Hamlet (hamlet)
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Char8 as S8
import Control.Exception (SomeException, try)
import Network.HTTP.Types (mkStatus)

data App = App

mkYesod "App" [parseRoutes|
/               HomeR GET
/not_found      NotFoundR POST
/first_thing    FirstThingR POST
/after_runRequestBody AfterRunRequestBodyR POST
/error-in-body ErrorInBodyR GET
/error-in-body-noeval ErrorInBodyNoEvalR GET
/override-status OverrideStatusR GET

-- https://github.com/yesodweb/yesod/issues/658
/builder BuilderR GET
/file-bad-len FileBadLenR GET
/file-bad-name FileBadNameR GET
|]

overrideStatus = mkStatus 15 "OVERRIDE"

instance Yesod App where
    errorHandler (InvalidArgs ["OVERRIDE"]) = sendResponseStatus overrideStatus ("OH HAI" :: String)
    errorHandler x = defaultErrorHandler x

getHomeR :: Handler Html
getHomeR = do
    $logDebug "Testing logging"
    defaultLayout $ toWidget [hamlet|
$doctype 5

<html>
  <body>
    <form method=post action=@{NotFoundR}>
      <input type=submit value="Not found">
    <form method=post action=@{FirstThingR}>
      <input type=submit value="Error is thrown first thing in handler">
    <form method=post action=@{AfterRunRequestBodyR}>
      <input type=submit value="BUGGY: Error thrown after runRequestBody">
|]

postNotFoundR, postFirstThingR, postAfterRunRequestBodyR :: Handler Html
postNotFoundR = do
   (_, _files) <- runRequestBody
   _ <- notFound
   getHomeR

postFirstThingR = do
   _ <- error "There was an error 3.14159"
   getHomeR

postAfterRunRequestBodyR = do
   x <- runRequestBody
   _ <- error $ show $ fst x
   getHomeR

getErrorInBodyR :: Handler Html
getErrorInBodyR = do
    let foo = error "error in body 19328" :: String
    defaultLayout [whamlet|#{foo}|]

getErrorInBodyNoEvalR :: Handler (DontFullyEvaluate Html)
getErrorInBodyNoEvalR = fmap DontFullyEvaluate getErrorInBodyR

getOverrideStatusR :: Handler ()
getOverrideStatusR = invalidArgs ["OVERRIDE"]

getBuilderR :: Handler TypedContent
getBuilderR = return $ TypedContent "ignored" $ ContentBuilder (error "builder-3.14159") Nothing

getFileBadLenR :: Handler TypedContent
getFileBadLenR = return $ TypedContent "ignored" $ ContentFile "yesod-core.cabal" (error "filebadlen")

getFileBadNameR :: Handler TypedContent
getFileBadNameR = return $ TypedContent "ignored" $ ContentFile (error "filebadname") Nothing

errorHandlingTest :: Spec
errorHandlingTest = describe "Test.ErrorHandling" $ do
      it "says not found" caseNotFound
      it "says 'There was an error' before runRequestBody" caseBefore
      it "says 'There was an error' after runRequestBody" caseAfter
      it "error in body == 500" caseErrorInBody
      it "error in body, no eval == 200" caseErrorInBodyNoEval
      it "can override status code" caseOverrideStatus
      it "builder" caseBuilder
      it "file with bad len" caseFileBadLen
      it "file with bad name" caseFileBadName

runner :: Session () -> IO ()
runner f = toWaiApp App >>= runSession f

caseNotFound :: IO ()
caseNotFound = runner $ do
    res <- request defaultRequest
            { pathInfo = ["not_found"]
            , requestMethod = "POST"
            }
    assertStatus 404 res
    assertBodyContains "Not Found" res

caseBefore :: IO ()
caseBefore = runner $ do
    res <- request defaultRequest
            { pathInfo = ["first_thing"]
            , requestMethod = "POST"
            }
    assertStatus 500 res
    assertBodyContains "There was an error 3.14159" res

caseAfter :: IO ()
caseAfter = runner $ do
    let content = "foo=bar&baz=bin12345"
    res <- srequest SRequest
        { simpleRequest = defaultRequest
            { pathInfo = ["after_runRequestBody"]
            , requestMethod = "POST"
            , requestHeaders =
                [ ("content-type", "application/x-www-form-urlencoded")
                , ("content-length", S8.pack $ show $ L.length content)
                ]
            }
        , simpleRequestBody = content
        }
    assertStatus 500 res
    assertBodyContains "bin12345" res

caseErrorInBody :: IO ()
caseErrorInBody = runner $ do
    res <- request defaultRequest { pathInfo = ["error-in-body"] }
    assertStatus 500 res
    assertBodyContains "error in body 19328" res

caseErrorInBodyNoEval :: IO ()
caseErrorInBodyNoEval = do
    eres <- try $ runner $ do
        _ <- request defaultRequest { pathInfo = ["error-in-body-noeval"] }
        return ()
    case eres of
        Left (_ :: SomeException) -> return ()
        Right _ -> error "Expected an exception"

caseOverrideStatus :: IO ()
caseOverrideStatus = runner $ do
    res <- request defaultRequest { pathInfo = ["override-status"] }
    assertStatus 15 res

caseBuilder :: IO ()
caseBuilder = runner $ do
    res <- request defaultRequest { pathInfo = ["builder"] }
    assertStatus 500 res
    assertBodyContains "builder-3.14159" res

caseFileBadLen :: IO ()
caseFileBadLen = runner $ do
    res <- request defaultRequest { pathInfo = ["file-bad-len"] }
    assertStatus 500 res
    assertBodyContains "filebadlen" res

caseFileBadName :: IO ()
caseFileBadName = runner $ do
    res <- request defaultRequest { pathInfo = ["file-bad-name"] }
    assertStatus 500 res
    assertBodyContains "filebadname" res
