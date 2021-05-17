module Types exposing (..)

import Array exposing (Array)
import AssocList exposing (Dict)
import AssocSet exposing (Set)
import Avataaars exposing (Avataaar)
import Browser exposing (UrlRequest)
import Browser.Navigation
import EmailAddress exposing (EmailAddress)
import GroupDescription exposing (GroupDescription)
import GroupForm exposing (CreateGroupError, GroupFormValidated, GroupVisibility, Model)
import GroupName exposing (GroupName)
import Id exposing (ClientId, CryptoHash, GroupId, LoginToken, SessionId, UserId)
import List.Nonempty exposing (Nonempty)
import Route exposing (Route)
import SendGrid exposing (Email)
import String.Nonempty exposing (NonemptyString)
import Time
import Untrusted exposing (Untrusted)
import Url exposing (Url)


type NavigationKey
    = RealNavigationKey Browser.Navigation.Key
    | MockNavigationKey


type FrontendModel
    = Loading NavigationKey ( Route, Maybe (CryptoHash LoginToken) )
    | Loaded LoadedFrontend


type alias LoadedFrontend =
    { navigationKey : NavigationKey
    , loginStatus : LoginStatus
    , route : Route
    , group : Maybe ( CryptoHash GroupId, Maybe FrontendGroup )
    , time : Time.Posix
    , lastConnectionCheck : Time.Posix
    , showLogin : Bool
    , loginForm : LoginForm
    , logs : Maybe (Array Log)
    , hasLoginError : Bool
    , groupForm : Model
    , groupCreated : Bool
    , showCreateGroup : Bool
    }


type alias LoginForm =
    { email : String
    , pressedSubmitEmail : Bool
    , emailSent : Bool
    }


type LoginStatus
    = LoggedIn (CryptoHash UserId) BackendUser
    | NotLoggedIn


type alias BackendModel =
    { users : Dict (CryptoHash UserId) BackendUser
    , groups : Dict (CryptoHash GroupId) BackendGroup
    , sessions : Dict SessionId (CryptoHash UserId)
    , connections : Dict SessionId (Nonempty ClientId)
    , logs : Array Log
    , time : Time.Posix
    , secretCounter : Int
    , pendingLoginTokens : Dict (CryptoHash LoginToken) LoginTokenData
    }


type alias LoginTokenData =
    { creationTime : Time.Posix, emailAddress : EmailAddress }


type Log
    = UntrustedCheckFailed Time.Posix ToBackendRequest
    | SendGridSendEmail Time.Posix (Result SendGrid.Error ()) EmailAddress


logTime : Log -> Time.Posix
logTime log =
    case log of
        UntrustedCheckFailed time _ ->
            time

        SendGridSendEmail time _ _ ->
            time


logIsError : Log -> Bool
logIsError log =
    case log of
        UntrustedCheckFailed _ _ ->
            True

        SendGridSendEmail _ result _ ->
            case result of
                Ok _ ->
                    False

                Err _ ->
                    True


logToString : Log -> String
logToString log =
    case log of
        SendGridSendEmail _ result email ->
            case result of
                Ok () ->
                    "Sent an email to " ++ EmailAddress.toString email

                Err error ->
                    "Tried sending a login email to "
                        ++ EmailAddress.toString email
                        ++ " but got this error "
                        ++ (case error of
                                SendGrid.StatusCode400 errors ->
                                    List.map (\a -> a.message) errors
                                        |> String.join ", "
                                        |> (++) "StatusCode400: "

                                SendGrid.StatusCode401 errors ->
                                    List.map (\a -> a.message) errors
                                        |> String.join ", "
                                        |> (++) "StatusCode401: "

                                SendGrid.StatusCode403 { errors } ->
                                    List.filterMap (\a -> a.message) errors
                                        |> String.join ", "
                                        |> (++) "StatusCode403: "

                                SendGrid.StatusCode413 errors ->
                                    List.map (\a -> a.message) errors
                                        |> String.join ", "
                                        |> (++) "StatusCode413: "

                                SendGrid.UnknownError { statusCode, body } ->
                                    "UnknownError: " ++ String.fromInt statusCode ++ " " ++ body

                                SendGrid.NetworkError ->
                                    "NetworkError"

                                SendGrid.Timeout ->
                                    "Timeout"

                                SendGrid.BadUrl url ->
                                    "BadUrl: " ++ url
                           )

        UntrustedCheckFailed _ toBackend ->
            "Trust check failed: TODO"


type alias BackendUser =
    { name : NonemptyString
    , emailAddress : EmailAddress
    , profileImage : Avataaar
    }


type alias FrontendUser =
    { name : NonemptyString
    , profileImage : Avataaar
    }


type alias BackendGroup =
    { ownerId : CryptoHash UserId
    , name : GroupName
    , description : GroupDescription
    , events : List Event
    , visibility : GroupVisibility
    }


type alias FrontendGroup =
    { ownerId : CryptoHash UserId
    , owner : FrontendUser
    , name : GroupName
    , events : List Event
    , visibility : GroupVisibility
    }


groupToFrontend : BackendUser -> BackendGroup -> FrontendGroup
groupToFrontend owner backendGroup =
    { ownerId = backendGroup.ownerId
    , owner = userToFrontend owner
    , name = backendGroup.name
    , events = backendGroup.events
    , visibility = backendGroup.visibility
    }


userToFrontend : BackendUser -> FrontendUser
userToFrontend backendUser =
    { name = backendUser.name
    , profileImage = backendUser.profileImage
    }


type alias Event =
    { attendees : Set (CryptoHash UserId)
    , startTime : Time.Posix
    , endTime : Time.Posix
    , isCancelled : Bool
    , description : NonemptyString
    }


type FrontendMsg
    = UrlClicked UrlRequest
    | UrlChanged Url
    | GotTime Time.Posix
    | PressedLogin
    | PressedLogout
    | TypedEmail String
    | PressedSubmitEmail
    | PressedCreateGroup
    | GroupFormMsg GroupForm.Msg


type ToBackend
    = ToBackend (Nonempty ToBackendRequest)


type ToBackendRequest
    = GetGroupRequest (CryptoHash GroupId)
    | CheckLoginRequest
    | LoginWithTokenRequest (CryptoHash LoginToken)
    | GetLoginTokenRequest Route (Untrusted EmailAddress)
    | GetAdminDataRequest
    | LogoutRequest
    | CreateGroupRequest (Untrusted GroupName) (Untrusted GroupDescription) GroupVisibility


type BackendMsg
    = SentLoginEmail EmailAddress (Result SendGrid.Error ())
    | BackendGotTime Time.Posix
    | Connected SessionId ClientId
    | Disconnected SessionId ClientId


type ToFrontend
    = GetGroupResponse (CryptoHash GroupId) (Maybe FrontendGroup)
    | CheckLoginResponse LoginStatus
    | LoginWithTokenResponse (Result () ( CryptoHash UserId, BackendUser ))
    | GetAdminDataResponse (Array Log)
    | CreateGroupResponse (Result CreateGroupError ( CryptoHash GroupId, BackendGroup ))
    | LogoutResponse
