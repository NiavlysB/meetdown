module Types exposing (..)

import AdminStatus exposing (AdminStatus)
import Array exposing (Array)
import AssocList as Dict exposing (Dict)
import AssocSet exposing (Set)
import BiDict.Assoc exposing (BiDict)
import Browser exposing (UrlRequest)
import Browser.Navigation
import CreateGroupPage exposing (CreateGroupError, GroupFormValidated)
import Description exposing (Description)
import EmailAddress exposing (EmailAddress)
import Event exposing (CancellationStatus, Event, EventType)
import EventDuration exposing (EventDuration)
import EventName exposing (EventName)
import FrontendUser exposing (FrontendUser)
import Group exposing (EventId, Group, GroupVisibility, JoinEventError)
import GroupName exposing (GroupName)
import GroupPage exposing (CreateEventError)
import Http
import HttpHelpers
import Id exposing (ClientId, DeleteUserToken, GroupId, Id, LoginToken, SessionId, SessionIdFirst4Chars, UserId)
import List.Nonempty exposing (Nonempty)
import MaxAttendees exposing (MaxAttendees)
import Name exposing (Name)
import Pixels exposing (Pixels)
import Postmark
import ProfileImage exposing (ProfileImage)
import ProfilePage
import Quantity exposing (Quantity)
import Route exposing (Route)
import SendGrid exposing (Email)
import Time
import TimeZone
import Untrusted exposing (Untrusted)
import Url exposing (Url)


type NavigationKey
    = RealNavigationKey Browser.Navigation.Key
    | MockNavigationKey


type FrontendModel
    = Loading LoadingFrontend
    | Loaded LoadedFrontend


type alias LoadingFrontend =
    { navigationKey : NavigationKey
    , route : Route
    , routeToken : Route.Token
    , windowSize : Maybe ( Quantity Int Pixels, Quantity Int Pixels )
    , time : Maybe Time.Posix
    , timezone : Maybe Time.Zone
    }


type alias LoadedFrontend =
    { navigationKey : NavigationKey
    , loginStatus : LoginStatus
    , route : Route
    , cachedGroups : Dict (Id GroupId) (Cache Group)
    , cachedUsers : Dict (Id UserId) (Cache FrontendUser)
    , time : Time.Posix
    , timezone : Time.Zone
    , lastConnectionCheck : Time.Posix
    , loginForm : LoginForm
    , logs : Maybe (Array Log)
    , hasLoginTokenError : Bool
    , groupForm : CreateGroupPage.Model
    , groupCreated : Bool
    , accountDeletedResult : Maybe (Result () ())
    , searchText : String
    , searchList : List (Id GroupId)
    , windowWidth : Quantity Int Pixels
    , windowHeight : Quantity Int Pixels
    , groupPage : Dict (Id GroupId) GroupPage.Model
    }


type GroupRequest
    = GroupNotFound_
    | GroupFound_ Group (Dict (Id UserId) FrontendUser)


type Cache item
    = ItemDoesNotExist
    | ItemCached item
    | ItemRequestPending


type AdminCache
    = AdminCacheNotRequested
    | AdminCached AdminModel
    | AdminCachePending


mapCache : (a -> a) -> Cache a -> Cache a
mapCache mapFunc userCache =
    case userCache of
        ItemDoesNotExist ->
            ItemDoesNotExist

        ItemCached item ->
            mapFunc item |> ItemCached

        ItemRequestPending ->
            ItemRequestPending


type alias LoginForm =
    { email : String
    , pressedSubmitEmail : Bool
    , emailSent : Maybe EmailAddress
    }


type LoginStatus
    = LoginStatusPending
    | LoggedIn LoggedIn_
    | NotLoggedIn { showLogin : Bool, joiningEvent : Maybe ( Id GroupId, EventId ) }


type alias LoggedIn_ =
    { userId : Id UserId
    , emailAddress : EmailAddress
    , profileForm : ProfilePage.Model
    , myGroups : Maybe (Set (Id GroupId))
    , adminState : AdminCache
    , adminStatus : AdminStatus
    }


type alias AdminModel =
    { cachedEmailAddress : Dict (Id UserId) EmailAddress
    , logs : Array Log
    , lastLogCheck : Time.Posix
    }


type alias BackendModel =
    { users : Dict (Id UserId) BackendUser
    , groups : Dict (Id GroupId) Group
    , deletedGroups : Dict (Id GroupId) Group
    , sessions : BiDict SessionId (Id UserId)
    , loginAttempts : Dict SessionId (Nonempty Time.Posix)
    , connections : Dict SessionId (Nonempty ClientId)
    , logs : Array Log
    , time : Time.Posix
    , secretCounter : Int
    , pendingLoginTokens : Dict (Id LoginToken) LoginTokenData
    , pendingDeleteUserTokens : Dict (Id DeleteUserToken) DeleteUserTokenData
    }


type alias LoginTokenData =
    { creationTime : Time.Posix, emailAddress : EmailAddress }


type alias DeleteUserTokenData =
    { creationTime : Time.Posix, userId : Id UserId }


type Log
    = LogUntrustedCheckFailed Time.Posix ToBackend SessionIdFirst4Chars
    | LogLoginEmail Time.Posix (Result Http.Error Postmark.PostmarkSendResponse) EmailAddress
    | LogDeleteAccountEmail Time.Posix (Result Http.Error Postmark.PostmarkSendResponse) (Id UserId)
    | LogEventReminderEmail Time.Posix (Result Http.Error Postmark.PostmarkSendResponse) (Id UserId) (Id GroupId) EventId
    | LogLoginTokenEmailRequestRateLimited Time.Posix EmailAddress SessionIdFirst4Chars
    | LogDeleteAccountEmailRequestRateLimited Time.Posix (Id UserId) SessionIdFirst4Chars


logData : AdminModel -> Log -> { time : Time.Posix, isError : Bool, message : String }
logData model log =
    let
        getEmailAddress userId =
            case Dict.get userId model.cachedEmailAddress of
                Just address ->
                    EmailAddress.toString address

                Nothing ->
                    "<not found>"

        emailErrorToString email error =
            "Tried sending a login email to "
                ++ email
                ++ " but got this error "
                ++ HttpHelpers.httpErrorToString error
    in
    case log of
        LogUntrustedCheckFailed time _ _ ->
            { time = time, isError = True, message = "Trust check failed: TODO" }

        LogLoginEmail time result emailAddress ->
            { time = time
            , isError =
                case result of
                    Ok _ ->
                        False

                    Err _ ->
                        True
            , message =
                case result of
                    Ok response ->
                        "Sent an email to " ++ EmailAddress.toString emailAddress

                    Err error ->
                        emailErrorToString (EmailAddress.toString emailAddress) error
            }

        LogDeleteAccountEmail time result userId ->
            { time = time
            , isError =
                case result of
                    Ok _ ->
                        False

                    Err _ ->
                        True
            , message =
                case result of
                    Ok _ ->
                        "Sent an email to " ++ getEmailAddress userId ++ " for deleting their account"

                    Err error ->
                        emailErrorToString (getEmailAddress userId) error
            }

        LogEventReminderEmail time result userId groupId eventId ->
            { time = time
            , isError =
                case result of
                    Ok _ ->
                        False

                    Err _ ->
                        True
            , message =
                case result of
                    Ok _ ->
                        "Sent an email to " ++ getEmailAddress userId ++ " to notify of an upcoming event"

                    Err error ->
                        emailErrorToString (getEmailAddress userId) error
            }

        LogLoginTokenEmailRequestRateLimited time emailAddress sessionId ->
            { time = time
            , isError = False
            , message =
                "Login request to "
                    ++ EmailAddress.toString emailAddress
                    ++ " was not sent due to rate limiting. First 4 chars of sessionId: "
                    ++ Id.sessionIdFirst4CharsToString sessionId
            }

        LogDeleteAccountEmailRequestRateLimited time userId sessionId ->
            { time = time
            , isError = False
            , message =
                "Login request to "
                    ++ getEmailAddress userId
                    ++ " was not sent due to rate limiting. First 4 chars of sessionId: "
                    ++ Id.sessionIdFirst4CharsToString sessionId
            }


type alias BackendUser =
    { name : Name
    , description : Description
    , emailAddress : EmailAddress
    , profileImage : ProfileImage
    , timezone : Time.Zone
    , allowEventReminders : Bool
    }


userToFrontend : BackendUser -> FrontendUser
userToFrontend backendUser =
    { name = backendUser.name
    , description = backendUser.description
    , profileImage = backendUser.profileImage
    }


type FrontendMsg
    = UrlClicked UrlRequest
    | UrlChanged Url
    | GotTime Time.Posix
    | PressedLogin
    | PressedLogout
    | TypedEmail String
    | PressedSubmitLogin
    | PressedCancelLogin
    | PressedCreateGroup
    | CreateGroupPageMsg CreateGroupPage.Msg
    | ProfileFormMsg ProfilePage.Msg
    | CroppedImage { requestId : Int, croppedImageUrl : String }
    | TypedSearchText String
    | SubmittedSearchBox
    | GroupPageMsg GroupPage.Msg
    | GotWindowSize (Quantity Int Pixels) (Quantity Int Pixels)
    | GotTimeZone (Result TimeZone.Error ( String, Time.Zone ))
    | ScrolledToTop
    | PressedEnableAdmin
    | PressedDisableAdmin


type ToBackend
    = GetGroupRequest (Id GroupId)
    | GetUserRequest (Id UserId)
    | CheckLoginRequest
    | LoginWithTokenRequest (Id LoginToken) (Maybe ( Id GroupId, EventId ))
    | GetLoginTokenRequest Route (Untrusted EmailAddress) (Maybe ( Id GroupId, EventId ))
    | GetAdminDataRequest
    | LogoutRequest
    | CreateGroupRequest (Untrusted GroupName) (Untrusted Description) GroupVisibility
    | ChangeNameRequest (Untrusted Name)
    | ChangeDescriptionRequest (Untrusted Description)
    | ChangeEmailAddressRequest (Untrusted EmailAddress)
    | SendDeleteUserEmailRequest
    | DeleteUserRequest (Id DeleteUserToken)
    | ChangeProfileImageRequest (Untrusted ProfileImage)
    | GetMyGroupsRequest
    | SearchGroupsRequest String
    | ChangeGroupNameRequest (Id GroupId) (Untrusted GroupName)
    | ChangeGroupDescriptionRequest (Id GroupId) (Untrusted Description)
    | ChangeGroupVisibilityRequest (Id GroupId) GroupVisibility
    | CreateEventRequest (Id GroupId) (Untrusted EventName) (Untrusted Description) (Untrusted EventType) Time.Posix (Untrusted EventDuration) (Untrusted MaxAttendees)
    | EditEventRequest (Id GroupId) EventId (Untrusted EventName) (Untrusted Description) (Untrusted EventType) Time.Posix (Untrusted EventDuration) (Untrusted MaxAttendees)
    | JoinEventRequest (Id GroupId) EventId
    | LeaveEventRequest (Id GroupId) EventId
    | ChangeEventCancellationStatusRequest (Id GroupId) EventId CancellationStatus
    | DeleteGroupAdminRequest (Id GroupId)


type BackendMsg
    = SentLoginEmail EmailAddress (Result Http.Error Postmark.PostmarkSendResponse)
    | SentDeleteUserEmail (Id UserId) (Result Http.Error Postmark.PostmarkSendResponse)
    | SentEventReminderEmail (Id UserId) (Id GroupId) EventId (Result Http.Error Postmark.PostmarkSendResponse)
    | BackendGotTime Time.Posix
    | Connected SessionId ClientId
    | Disconnected SessionId ClientId


type ToFrontend
    = GetGroupResponse (Id GroupId) GroupRequest
    | GetUserResponse (Id UserId) (Result () FrontendUser)
    | CheckLoginResponse (Maybe { userId : Id UserId, user : BackendUser, isAdmin : Bool })
    | LoginWithTokenResponse (Result () { userId : Id UserId, user : BackendUser, isAdmin : Bool })
    | GetAdminDataResponse AdminModel
    | CreateGroupResponse (Result CreateGroupError ( Id GroupId, Group ))
    | LogoutResponse
    | ChangeNameResponse Name
    | ChangeDescriptionResponse Description
    | ChangeEmailAddressResponse EmailAddress
    | DeleteUserResponse (Result () ())
    | ChangeProfileImageResponse ProfileImage
    | GetMyGroupsResponse (List ( Id GroupId, Group ))
    | SearchGroupsResponse String (List ( Id GroupId, Group ))
    | ChangeGroupNameResponse (Id GroupId) GroupName
    | ChangeGroupDescriptionResponse (Id GroupId) Description
    | ChangeGroupVisibilityResponse (Id GroupId) GroupVisibility
    | CreateEventResponse (Id GroupId) (Result CreateEventError Event)
    | EditEventResponse (Id GroupId) EventId (Result Group.EditEventError Event) Time.Posix
    | JoinEventResponse (Id GroupId) EventId (Result JoinEventError ())
    | LeaveEventResponse (Id GroupId) EventId (Result () ())
    | ChangeEventCancellationStatusResponse (Id GroupId) EventId (Result Group.EditCancellationStatusError CancellationStatus) Time.Posix
    | DeleteGroupAdminResponse (Id GroupId)
