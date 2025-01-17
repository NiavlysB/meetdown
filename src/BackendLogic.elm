module BackendLogic exposing (Effects, Subscriptions, createApp, deleteAccountEmailContent, deleteAccountEmailSubject, eventReminderEmailContent, eventReminderEmailSubject, loginEmailContent, loginEmailLink, loginEmailSubject, sendGridApiKey)

import Address
import Array
import AssocList as Dict exposing (Dict)
import AssocSet as Set
import BiDict.Assoc as BiDict
import CreateGroupPage exposing (CreateGroupError(..))
import Description exposing (Description)
import Duration exposing (Duration)
import Email.Html
import Email.Html.Attributes
import EmailAddress exposing (EmailAddress)
import Env
import Event exposing (Event)
import EventName
import Group exposing (EventId, Group, GroupVisibility)
import GroupName exposing (GroupName)
import GroupPage exposing (CreateEventError(..))
import Http
import Id exposing (ClientId, DeleteUserToken, GroupId, Id, LoginToken, SessionId, UserId)
import Link
import List.Extra as List
import List.Nonempty
import Name
import Postmark
import ProfileImage
import Quantity
import Route exposing (Route(..))
import SendGrid
import String.Nonempty exposing (NonemptyString(..))
import Time
import Toop exposing (T3(..), T4(..), T5(..))
import Types exposing (..)
import Untrusted


type alias Effects cmd =
    { batch : List cmd -> cmd
    , none : cmd
    , sendToFrontend : ClientId -> ToFrontend -> cmd
    , sendToFrontends : List ClientId -> ToFrontend -> cmd
    , sendLoginEmail :
        (Result Http.Error Postmark.PostmarkSendResponse -> BackendMsg)
        -> EmailAddress
        -> Route
        -> Id LoginToken
        -> Maybe ( Id GroupId, EventId )
        -> cmd
    , sendDeleteUserEmail : (Result Http.Error Postmark.PostmarkSendResponse -> BackendMsg) -> EmailAddress -> Id DeleteUserToken -> cmd
    , sendEventReminderEmail :
        (Result Http.Error Postmark.PostmarkSendResponse -> BackendMsg)
        -> Id GroupId
        -> GroupName
        -> Event
        -> Time.Zone
        -> EmailAddress
        -> cmd
    , getTime : (Time.Posix -> BackendMsg) -> cmd
    }


type alias Subscriptions sub =
    { batch : List sub -> sub
    , timeEvery : Duration -> (Time.Posix -> BackendMsg) -> sub
    , onConnect : (SessionId -> ClientId -> BackendMsg) -> sub
    , onDisconnect : (SessionId -> ClientId -> BackendMsg) -> sub
    }


createApp :
    Effects cmd
    -> Subscriptions sub
    ->
        { init : ( BackendModel, cmd )
        , update : BackendMsg -> BackendModel -> ( BackendModel, cmd )
        , updateFromFrontend : Id.SessionId -> Id.ClientId -> ToBackend -> BackendModel -> ( BackendModel, cmd )
        , subscriptions : BackendModel -> sub
        }
createApp cmds subs =
    { init = init cmds
    , update = update cmds
    , updateFromFrontend = updateFromFrontend cmds
    , subscriptions = subscriptions subs
    }


sendGridApiKey : SendGrid.ApiKey
sendGridApiKey =
    SendGrid.apiKey Env.sendGridApiKey_


loginEmailLink : Route -> Id LoginToken -> Maybe ( Id GroupId, EventId ) -> String
loginEmailLink route loginToken maybeJoinEvent =
    Env.domain ++ Route.encodeWithToken route (Route.LoginToken loginToken maybeJoinEvent)


init : Effects cmd -> ( BackendModel, cmd )
init effects =
    ( { users = Dict.empty
      , groups = Dict.empty
      , deletedGroups = Dict.empty
      , sessions = BiDict.empty
      , loginAttempts = Dict.empty
      , connections = Dict.empty
      , logs = Array.empty
      , time = Time.millisToPosix 0
      , secretCounter = 0
      , pendingLoginTokens = Dict.empty
      , pendingDeleteUserTokens = Dict.empty
      }
    , effects.getTime BackendGotTime
    )


subscriptions : Subscriptions subs -> BackendModel -> subs
subscriptions subs _ =
    subs.batch
        [ subs.timeEvery (Duration.seconds 15) BackendGotTime
        , subs.onConnect Connected
        , subs.onDisconnect Disconnected
        ]


handleNotifications : Effects cmd -> Time.Posix -> Time.Posix -> BackendModel -> cmd
handleNotifications cmds lastCheck currentTime backendModel =
    Dict.toList backendModel.groups
        |> List.concatMap
            (\( groupId, group ) ->
                let
                    { futureEvents } =
                        Group.events currentTime group
                in
                List.concatMap
                    (\( eventId, event ) ->
                        let
                            start =
                                Event.startTime event
                        in
                        if
                            (Duration.from lastCheck start |> Quantity.greaterThan Duration.day)
                                && not (Duration.from currentTime start |> Quantity.greaterThan Duration.day)
                        then
                            Event.attendees event
                                |> Set.toList
                                |> List.filterMap
                                    (\userId ->
                                        case getUser userId backendModel of
                                            Just user ->
                                                cmds.sendEventReminderEmail
                                                    (SentEventReminderEmail userId groupId eventId)
                                                    groupId
                                                    (Group.name group)
                                                    event
                                                    user.timezone
                                                    user.emailAddress
                                                    |> Just

                                            Nothing ->
                                                Nothing
                                    )

                        else
                            []
                    )
                    futureEvents
            )
        |> cmds.batch


update : Effects cmd -> BackendMsg -> BackendModel -> ( BackendModel, cmd )
update cmds msg model =
    case msg of
        SentLoginEmail userId result ->
            ( addLog (LogLoginEmail model.time result userId) model, cmds.none )

        BackendGotTime time ->
            ( { model
                | time = time
                , loginAttempts =
                    Dict.toList model.loginAttempts
                        |> List.filterMap
                            (\( sessionId, logins ) ->
                                List.Nonempty.toList logins
                                    |> List.filter
                                        (\loginTime -> Duration.from loginTime time |> Quantity.lessThan (Duration.seconds 30))
                                    |> List.Nonempty.fromList
                                    |> Maybe.map (Tuple.pair sessionId)
                            )
                        |> Dict.fromList
              }
            , handleNotifications cmds model.time time model
            )

        Connected sessionId clientId ->
            ( { model
                | connections =
                    Dict.update sessionId
                        (Maybe.map (List.Nonempty.cons clientId)
                            >> Maybe.withDefault (List.Nonempty.fromElement clientId)
                            >> Just
                        )
                        model.connections
              }
            , cmds.none
            )

        Disconnected sessionId clientId ->
            ( { model
                | connections =
                    Dict.update sessionId
                        (Maybe.andThen (List.Nonempty.toList >> List.remove clientId >> List.Nonempty.fromList))
                        model.connections
              }
            , cmds.none
            )

        SentDeleteUserEmail userId result ->
            ( addLog (LogDeleteAccountEmail model.time result userId) model, cmds.none )

        SentEventReminderEmail userId groupId eventId result ->
            ( addLog (LogEventReminderEmail model.time result userId groupId eventId) model, cmds.none )


addLog : Log -> BackendModel -> BackendModel
addLog log model =
    { model | logs = Array.push log model.logs }


updateFromFrontend : Effects cmd -> SessionId -> ClientId -> ToBackend -> BackendModel -> ( BackendModel, cmd )
updateFromFrontend cmds sessionId clientId msg model =
    case msg of
        GetGroupRequest groupId ->
            ( model
            , (case getGroup groupId model of
                Just group ->
                    case getUserFromSessionId sessionId model of
                        Just ( userId, user ) ->
                            GroupFound_
                                group
                                (if userId == Group.ownerId group then
                                    Dict.empty

                                 else
                                    case getUser (Group.ownerId group) model of
                                        Just groupOwner ->
                                            Dict.singleton (Group.ownerId group) (userToFrontend groupOwner)

                                        Nothing ->
                                            Dict.empty
                                )

                        Nothing ->
                            GroupFound_ group
                                (case getUser (Group.ownerId group) model of
                                    Just user ->
                                        Dict.singleton (Group.ownerId group) (userToFrontend user)

                                    Nothing ->
                                        Dict.empty
                                )

                Nothing ->
                    GroupNotFound_
              )
                |> GetGroupResponse groupId
                |> cmds.sendToFrontend clientId
            )

        GetUserRequest userId ->
            case getUser userId model of
                Just user ->
                    ( model
                    , Ok (Types.userToFrontend user) |> GetUserResponse userId |> cmds.sendToFrontend clientId
                    )

                Nothing ->
                    ( model, Err () |> GetUserResponse userId |> cmds.sendToFrontend clientId )

        CheckLoginRequest ->
            ( model, checkLogin sessionId model |> CheckLoginResponse |> cmds.sendToFrontend clientId )

        GetLoginTokenRequest route untrustedEmail maybeJoinEvent ->
            case Untrusted.validateEmailAddress untrustedEmail of
                Just email ->
                    let
                        ( model2, loginToken ) =
                            Id.getUniqueId model
                    in
                    if loginIsRateLimited sessionId email model then
                        ( addLog
                            (LogLoginTokenEmailRequestRateLimited model.time email (Id.anonymizeSessionId sessionId))
                            model
                        , cmds.none
                        )

                    else
                        ( { model2
                            | pendingLoginTokens =
                                Dict.insert
                                    loginToken
                                    { creationTime = model2.time, emailAddress = email }
                                    model2.pendingLoginTokens
                            , loginAttempts =
                                Dict.update
                                    sessionId
                                    (\maybeAttempts ->
                                        case maybeAttempts of
                                            Just attempts ->
                                                List.Nonempty.cons model.time attempts |> Just

                                            Nothing ->
                                                List.Nonempty.fromElement model.time |> Just
                                    )
                                    model.loginAttempts
                          }
                        , cmds.sendLoginEmail (SentLoginEmail email) email route loginToken maybeJoinEvent
                        )

                Nothing ->
                    ( addLog (LogUntrustedCheckFailed model.time msg (Id.anonymizeSessionId sessionId)) model
                    , cmds.none
                    )

        GetAdminDataRequest ->
            adminAuthorization
                cmds
                sessionId
                model
                (\_ ->
                    ( model
                    , cmds.sendToFrontend
                        clientId
                        (GetAdminDataResponse
                            { cachedEmailAddress = Dict.map (\_ value -> value.emailAddress) model.users
                            , logs = model.logs
                            , lastLogCheck = model.time
                            }
                        )
                    )
                )

        LoginWithTokenRequest loginToken maybeJoinEvent ->
            getAndRemoveLoginToken (loginWithToken cmds sessionId clientId maybeJoinEvent) loginToken model

        LogoutRequest ->
            ( { model | sessions = BiDict.remove sessionId model.sessions }
            , case Dict.get sessionId model.connections of
                Just clientIds ->
                    cmds.sendToFrontends (List.Nonempty.toList clientIds) LogoutResponse

                Nothing ->
                    cmds.none
            )

        CreateGroupRequest untrustedName untrustedDescription visibility ->
            userAuthorization
                cmds
                sessionId
                model
                (\( userId, _ ) ->
                    case
                        ( Untrusted.validateGroupName untrustedName
                        , Untrusted.description untrustedDescription
                        )
                    of
                        ( Just groupName, Just description ) ->
                            addGroup cmds clientId userId groupName description visibility model

                        _ ->
                            ( addLog (LogUntrustedCheckFailed model.time msg (Id.anonymizeSessionId sessionId)) model
                            , cmds.none
                            )
                )

        ChangeNameRequest untrustedName ->
            case Untrusted.validateName untrustedName of
                Just name ->
                    userAuthorization
                        cmds
                        sessionId
                        model
                        (\( userId, user ) ->
                            ( { model | users = Dict.insert userId { user | name = name } model.users }
                            , cmds.sendToFrontends
                                (getClientIdsForUser userId model)
                                (ChangeNameResponse name)
                            )
                        )

                Nothing ->
                    ( addLog (LogUntrustedCheckFailed model.time msg (Id.anonymizeSessionId sessionId)) model
                    , cmds.none
                    )

        ChangeDescriptionRequest untrustedDescription ->
            case Untrusted.description untrustedDescription of
                Just description ->
                    userAuthorization
                        cmds
                        sessionId
                        model
                        (\( userId, user ) ->
                            ( { model | users = Dict.insert userId { user | description = description } model.users }
                            , cmds.sendToFrontends
                                (getClientIdsForUser userId model)
                                (ChangeDescriptionResponse description)
                            )
                        )

                Nothing ->
                    ( addLog (LogUntrustedCheckFailed model.time msg (Id.anonymizeSessionId sessionId)) model
                    , cmds.none
                    )

        ChangeEmailAddressRequest untrustedEmailAddress ->
            case Untrusted.validateEmailAddress untrustedEmailAddress of
                Just emailAddress ->
                    userAuthorization
                        cmds
                        sessionId
                        model
                        (\( userId, user ) ->
                            ( { model
                                | users =
                                    Dict.insert
                                        userId
                                        { user | emailAddress = emailAddress }
                                        model.users
                              }
                            , cmds.sendToFrontends
                                (getClientIdsForUser userId model)
                                (ChangeEmailAddressResponse emailAddress)
                            )
                        )

                Nothing ->
                    ( addLog (LogUntrustedCheckFailed model.time msg (Id.anonymizeSessionId sessionId)) model
                    , cmds.none
                    )

        SendDeleteUserEmailRequest ->
            userAuthorization
                cmds
                sessionId
                model
                (\( userId, user ) ->
                    let
                        rateLimited =
                            Dict.toList model.pendingDeleteUserTokens
                                |> List.filter (Tuple.second >> .userId >> (==) userId)
                                |> List.maximumBy (Tuple.second >> .creationTime >> Time.posixToMillis)
                                |> Maybe.map
                                    (\( _, { creationTime } ) ->
                                        Duration.from creationTime model.time |> Quantity.lessThan (Duration.seconds 10)
                                    )
                                |> Maybe.withDefault False

                        ( model2, deleteUserToken ) =
                            Id.getUniqueId model
                    in
                    if rateLimited then
                        ( addLog
                            (LogDeleteAccountEmailRequestRateLimited model.time userId (Id.anonymizeSessionId sessionId))
                            model
                        , cmds.none
                        )

                    else
                        ( { model2
                            | pendingDeleteUserTokens =
                                Dict.insert
                                    deleteUserToken
                                    { creationTime = model.time, userId = userId }
                                    model2.pendingDeleteUserTokens
                          }
                        , cmds.sendDeleteUserEmail
                            (SentDeleteUserEmail userId)
                            user.emailAddress
                            deleteUserToken
                        )
                )

        DeleteUserRequest deleteUserToken ->
            getAndRemoveDeleteUserToken (handleDeleteUserRequest cmds clientId) deleteUserToken model

        ChangeProfileImageRequest untrustedProfileImage ->
            userAuthorization
                cmds
                sessionId
                model
                (\( userId, user ) ->
                    case Untrusted.validateProfileImage untrustedProfileImage of
                        Just profileImage ->
                            let
                                response =
                                    ChangeProfileImageResponse profileImage
                            in
                            ( { model
                                | users =
                                    Dict.insert
                                        userId
                                        { user | profileImage = profileImage }
                                        model.users
                              }
                            , cmds.sendToFrontends (getClientIdsForUser userId model) response
                            )

                        Nothing ->
                            ( addLog (LogUntrustedCheckFailed model.time msg (Id.anonymizeSessionId sessionId)) model
                            , cmds.none
                            )
                )

        GetMyGroupsRequest ->
            userAuthorization
                cmds
                sessionId
                model
                (\( userId, _ ) ->
                    ( model
                    , Dict.toList model.groups
                        |> List.filter
                            (\( _, group ) -> Group.ownerId group == userId)
                        |> GetMyGroupsResponse
                        |> cmds.sendToFrontend clientId
                    )
                )

        SearchGroupsRequest searchText ->
            if String.length searchText < 1000 then
                ( model
                , Dict.toList model.groups
                    |> List.filter (Tuple.second >> Group.visibility >> (==) Group.PublicGroup)
                    |> SearchGroupsResponse searchText
                    |> cmds.sendToFrontend clientId
                )

            else
                ( model, cmds.none )

        ChangeGroupNameRequest groupId untrustedName ->
            case Untrusted.validateGroupName untrustedName of
                Just name ->
                    userWithGroupAuthorization
                        cmds
                        sessionId
                        groupId
                        model
                        (\( userId, _, group ) ->
                            ( { model
                                | groups =
                                    Dict.insert groupId (Group.withName name group) model.groups
                              }
                            , cmds.sendToFrontends
                                (getClientIdsForUser userId model)
                                (ChangeGroupNameResponse groupId name)
                            )
                        )

                Nothing ->
                    ( addLog (LogUntrustedCheckFailed model.time msg (Id.anonymizeSessionId sessionId)) model
                    , cmds.none
                    )

        ChangeGroupDescriptionRequest groupId untrustedDescription ->
            case Untrusted.description untrustedDescription of
                Just description ->
                    userWithGroupAuthorization
                        cmds
                        sessionId
                        groupId
                        model
                        (\( userId, _, group ) ->
                            ( { model
                                | groups =
                                    Dict.insert groupId (Group.withDescription description group) model.groups
                              }
                            , cmds.sendToFrontends
                                (getClientIdsForUser userId model)
                                (ChangeGroupDescriptionResponse groupId description)
                            )
                        )

                Nothing ->
                    ( addLog (LogUntrustedCheckFailed model.time msg (Id.anonymizeSessionId sessionId)) model
                    , cmds.none
                    )

        CreateEventRequest groupId eventName_ description_ eventType_ startTime eventDuration_ maxAttendees_ ->
            case
                T5
                    (Untrusted.eventName eventName_)
                    (Untrusted.description description_)
                    (Untrusted.eventType eventType_)
                    (Untrusted.eventDuration eventDuration_)
                    (Untrusted.maxAttendees maxAttendees_)
            of
                T5 (Just eventName) (Just description) (Just eventType) (Just eventDuration) (Just maxAttendees) ->
                    userWithGroupAuthorization
                        cmds
                        sessionId
                        groupId
                        model
                        (\( userId, _, group ) ->
                            if Group.totalEvents group > 1000 then
                                ( model
                                , cmds.sendToFrontend clientId (CreateEventResponse groupId (Err TooManyEvents))
                                )

                            else if Duration.from model.time startTime |> Quantity.lessThanZero then
                                ( model
                                , cmds.sendToFrontend
                                    clientId
                                    (CreateEventResponse groupId (Err EventStartsInThePast))
                                )

                            else
                                let
                                    newEvent : Event
                                    newEvent =
                                        Event.newEvent
                                            userId
                                            eventName
                                            description
                                            eventType
                                            startTime
                                            eventDuration
                                            model.time
                                            maxAttendees
                                in
                                case Group.addEvent newEvent group of
                                    Ok newGroup ->
                                        ( { model | groups = Dict.insert groupId newGroup model.groups }
                                        , cmds.sendToFrontends
                                            (getClientIdsForUser userId model)
                                            (CreateEventResponse groupId (Ok newEvent))
                                        )

                                    Err overlappingEvents ->
                                        ( model
                                        , cmds.sendToFrontend
                                            clientId
                                            (CreateEventResponse groupId (Err (EventOverlapsOtherEvents overlappingEvents)))
                                        )
                        )

                _ ->
                    ( addLog (LogUntrustedCheckFailed model.time msg (Id.anonymizeSessionId sessionId)) model
                    , cmds.none
                    )

        JoinEventRequest groupId eventId ->
            userAuthorization
                cmds
                sessionId
                model
                (\( userId, _ ) -> joinEvent cmds clientId userId ( groupId, eventId ) model)

        LeaveEventRequest groupId eventId ->
            userAuthorization
                cmds
                sessionId
                model
                (\( userId, _ ) ->
                    case getGroup groupId model of
                        Just group ->
                            ( { model
                                | groups =
                                    Dict.insert groupId (Group.leaveEvent userId eventId group) model.groups
                              }
                            , cmds.sendToFrontends
                                (getClientIdsForUser userId model)
                                (LeaveEventResponse groupId eventId (Ok ()))
                            )

                        Nothing ->
                            ( model
                            , cmds.sendToFrontend
                                clientId
                                (LeaveEventResponse groupId eventId (Err ()))
                            )
                )

        EditEventRequest groupId eventId eventName_ description_ eventType_ startTime eventDuration_ maxAttendees_ ->
            case
                T5
                    (Untrusted.eventName eventName_)
                    (Untrusted.description description_)
                    (Untrusted.eventType eventType_)
                    (Untrusted.eventDuration eventDuration_)
                    (Untrusted.maxAttendees maxAttendees_)
            of
                T5 (Just eventName) (Just description) (Just eventType) (Just eventDuration) (Just maxAttendees) ->
                    userWithGroupAuthorization
                        cmds
                        sessionId
                        groupId
                        model
                        (\( userId, _, group ) ->
                            case
                                Group.editEvent model.time
                                    eventId
                                    (Event.withName eventName
                                        >> Event.withDescription description
                                        >> Event.withEventType eventType
                                        >> Event.withDuration eventDuration
                                        >> Event.withStartTime startTime
                                        >> Event.withMaxAttendees maxAttendees
                                    )
                                    group
                            of
                                Ok ( newEvent, newGroup ) ->
                                    ( { model | groups = Dict.insert groupId newGroup model.groups }
                                    , cmds.sendToFrontends
                                        (getClientIdsForUser userId model)
                                        (EditEventResponse groupId eventId (Ok newEvent) model.time)
                                    )

                                Err error ->
                                    ( model
                                    , cmds.sendToFrontend
                                        clientId
                                        (EditEventResponse groupId eventId (Err error) model.time)
                                    )
                        )

                _ ->
                    ( addLog (LogUntrustedCheckFailed model.time msg (Id.anonymizeSessionId sessionId)) model
                    , cmds.none
                    )

        ChangeEventCancellationStatusRequest groupId eventId cancellationStatus ->
            userWithGroupAuthorization
                cmds
                sessionId
                groupId
                model
                (\( userId, _, group ) ->
                    case Group.editCancellationStatus model.time eventId cancellationStatus group of
                        Ok newGroup ->
                            ( { model | groups = Dict.insert groupId newGroup model.groups }
                            , cmds.sendToFrontends
                                (getClientIdsForUser userId model)
                                (ChangeEventCancellationStatusResponse
                                    groupId
                                    eventId
                                    (Ok cancellationStatus)
                                    model.time
                                )
                            )

                        Err error ->
                            ( model
                            , cmds.sendToFrontend
                                clientId
                                (ChangeEventCancellationStatusResponse groupId eventId (Err error) model.time)
                            )
                )

        ChangeGroupVisibilityRequest groupId groupVisibility ->
            userWithGroupAuthorization
                cmds
                sessionId
                groupId
                model
                (\( userId, _, group ) ->
                    ( { model | groups = Dict.insert groupId (Group.withVisibility groupVisibility group) model.groups }
                    , cmds.sendToFrontends
                        (getClientIdsForUser userId model)
                        (ChangeGroupVisibilityResponse groupId groupVisibility)
                    )
                )

        DeleteGroupAdminRequest groupId ->
            adminAuthorization
                cmds
                sessionId
                model
                (\( userId, _ ) ->
                    case Dict.get groupId model.groups of
                        Just group ->
                            ( { model
                                | groups = Dict.remove groupId model.groups
                                , deletedGroups = Dict.insert groupId group model.deletedGroups
                              }
                            , cmds.sendToFrontends
                                (getClientIdsForUser userId model)
                                (DeleteGroupAdminResponse groupId)
                            )

                        Nothing ->
                            ( model, cmds.none )
                )


loginIsRateLimited : SessionId -> EmailAddress -> BackendModel -> Bool
loginIsRateLimited sessionId emailAddress model =
    if
        Dict.get sessionId model.loginAttempts
            |> Maybe.map List.Nonempty.toList
            |> Maybe.withDefault []
            |> List.filter (\time -> Duration.from time model.time |> Quantity.lessThan (Duration.seconds 10))
            |> List.length
            |> (\a -> a > 0)
    then
        True

    else
        case Dict.values model.pendingLoginTokens |> List.find (.emailAddress >> (==) emailAddress) of
            Just { creationTime } ->
                if Duration.from creationTime model.time |> Quantity.lessThan Duration.minute then
                    True

                else
                    False

            Nothing ->
                False


handleDeleteUserRequest : Effects cmd -> ClientId -> Maybe DeleteUserTokenData -> BackendModel -> ( BackendModel, cmd )
handleDeleteUserRequest cmds clientId maybeDeleteUserTokenData model =
    case maybeDeleteUserTokenData of
        Just { creationTime, userId } ->
            if Duration.from creationTime model.time |> Quantity.lessThan Duration.hour then
                ( deleteUser userId model
                , cmds.sendToFrontends (getClientIdsForUser userId model) (DeleteUserResponse (Ok ()))
                )

            else
                ( model, cmds.sendToFrontend clientId (DeleteUserResponse (Err ())) )

        Nothing ->
            ( model, cmds.sendToFrontend clientId (DeleteUserResponse (Err ())) )


deleteUser : Id UserId -> BackendModel -> BackendModel
deleteUser userId model =
    { model
        | users = Dict.remove userId model.users
        , groups = Dict.filter (\_ group -> Group.ownerId group /= userId) model.groups
        , sessions = BiDict.filter (\_ userId_ -> userId_ /= userId) model.sessions
    }


getClientIdsForUser : Id UserId -> BackendModel -> List ClientId
getClientIdsForUser userId model =
    BiDict.getReverse userId model.sessions
        |> Set.toList
        |> List.concatMap
            (\sessionId_ ->
                case Dict.get sessionId_ model.connections of
                    Just nonempty ->
                        List.Nonempty.toList nonempty

                    Nothing ->
                        []
            )


loginWithToken :
    Effects cmd
    -> SessionId
    -> ClientId
    -> Maybe ( Id GroupId, EventId )
    -> Maybe LoginTokenData
    -> BackendModel
    -> ( BackendModel, cmd )
loginWithToken cmds sessionId clientId maybeJoinEvent maybeLoginTokenData model =
    let
        loginResponse : ( Id UserId, BackendUser ) -> cmd
        loginResponse ( userId, userEntry ) =
            case Dict.get sessionId model.connections of
                Just clientIds ->
                    { userId = userId, user = userEntry, isAdmin = isAdmin userEntry }
                        |> Ok
                        |> LoginWithTokenResponse
                        |> cmds.sendToFrontends (List.Nonempty.toList clientIds)

                Nothing ->
                    cmds.none

        addSession : Id UserId -> BackendModel -> BackendModel
        addSession userId model_ =
            { model_ | sessions = BiDict.insert sessionId userId model_.sessions }

        joinEventHelper : Id UserId -> BackendModel -> ( BackendModel, cmd )
        joinEventHelper userId model_ =
            case maybeJoinEvent of
                Just joinEvent_ ->
                    joinEvent cmds clientId userId joinEvent_ model_

                Nothing ->
                    ( model_, cmds.none )
    in
    case maybeLoginTokenData of
        Just { creationTime, emailAddress } ->
            if Duration.from creationTime model.time |> Quantity.lessThan Duration.hour then
                case Dict.toList model.users |> List.find (Tuple.second >> .emailAddress >> (==) emailAddress) of
                    Just ( userId, user ) ->
                        let
                            ( model2, effects ) =
                                joinEventHelper userId model
                        in
                        ( addSession userId model2
                        , cmds.batch [ loginResponse ( userId, user ), effects ]
                        )

                    Nothing ->
                        let
                            ( model2, userId ) =
                                Id.getUniqueShortId (\id_ model_ -> Dict.member id_ model_.users |> not) model

                            newUser : BackendUser
                            newUser =
                                { name = Name.anonymous
                                , description = Description.empty
                                , emailAddress = emailAddress
                                , profileImage = ProfileImage.defaultImage
                                , timezone = Time.utc
                                , allowEventReminders = True
                                }

                            ( model3, effects ) =
                                { model2 | users = Dict.insert userId newUser model2.users }
                                    |> addSession userId
                                    |> joinEventHelper userId
                        in
                        ( model3
                        , cmds.batch [ loginResponse ( userId, newUser ), effects ]
                        )

            else
                ( model, Err () |> LoginWithTokenResponse |> cmds.sendToFrontend clientId )

        Nothing ->
            ( model, Err () |> LoginWithTokenResponse |> cmds.sendToFrontend clientId )


joinEvent : Effects cmd -> ClientId -> Id UserId -> ( Id GroupId, EventId ) -> BackendModel -> ( BackendModel, cmd )
joinEvent cmds clientId userId ( groupId, eventId ) model =
    case getGroup groupId model of
        Just group ->
            case Group.joinEvent userId eventId group of
                Ok newGroup ->
                    ( { model | groups = Dict.insert groupId newGroup model.groups }
                    , cmds.sendToFrontends
                        (getClientIdsForUser userId model)
                        (JoinEventResponse groupId eventId (Ok ()))
                    )

                Err error ->
                    ( model
                    , cmds.sendToFrontend clientId (JoinEventResponse groupId eventId (Err error))
                    )

        Nothing ->
            ( model, cmds.none )


getAndRemoveLoginToken :
    (Maybe LoginTokenData -> BackendModel -> ( BackendModel, cmds ))
    -> Id LoginToken
    -> BackendModel
    -> ( BackendModel, cmds )
getAndRemoveLoginToken updateFunc loginToken model =
    updateFunc
        (Dict.get loginToken model.pendingLoginTokens)
        { model | pendingLoginTokens = Dict.remove loginToken model.pendingLoginTokens }


getAndRemoveDeleteUserToken :
    (Maybe DeleteUserTokenData -> BackendModel -> ( BackendModel, cmd ))
    -> Id DeleteUserToken
    -> BackendModel
    -> ( BackendModel, cmd )
getAndRemoveDeleteUserToken updateFunc deleteUserToken model =
    updateFunc
        (Dict.get deleteUserToken model.pendingDeleteUserTokens)
        { model | pendingDeleteUserTokens = Dict.remove deleteUserToken model.pendingDeleteUserTokens }


addGroup :
    Effects cmd
    -> ClientId
    -> Id UserId
    -> GroupName
    -> Description
    -> GroupVisibility
    -> BackendModel
    -> ( BackendModel, cmd )
addGroup cmds clientId userId name description visibility model =
    if Dict.values model.groups |> List.any (Group.name >> GroupName.namesMatch name) then
        ( model, Err GroupNameAlreadyInUse |> CreateGroupResponse |> cmds.sendToFrontend clientId )

    else
        let
            ( model2, groupId ) =
                Id.getUniqueShortId (\id_ model_ -> Dict.member id_ model_.groups |> not) model

            newGroup =
                Group.init userId name description visibility model2.time
        in
        ( { model2 | groups = Dict.insert groupId newGroup model2.groups }
        , Ok ( groupId, newGroup ) |> CreateGroupResponse |> cmds.sendToFrontend clientId
        )


userAuthorization :
    Effects cmd
    -> SessionId
    -> BackendModel
    -> (( Id UserId, BackendUser ) -> ( BackendModel, cmd ))
    -> ( BackendModel, cmd )
userAuthorization cmds sessionId model updateFunc =
    case checkLogin sessionId model of
        Just { userId, user } ->
            updateFunc ( userId, user )

        Nothing ->
            ( model, cmds.none )


userWithGroupAuthorization :
    Effects cmd
    -> SessionId
    -> Id GroupId
    -> BackendModel
    -> (( Id UserId, BackendUser, Group ) -> ( BackendModel, cmd ))
    -> ( BackendModel, cmd )
userWithGroupAuthorization cmds sessionId groupId model updateFunc =
    case checkLogin sessionId model of
        Just { userId, user } ->
            case getGroup groupId model of
                Just group ->
                    if Group.ownerId group == userId || isAdmin user then
                        updateFunc ( userId, user, group )

                    else
                        ( model, cmds.none )

                Nothing ->
                    ( model, cmds.none )

        Nothing ->
            ( model, cmds.none )


adminAuthorization :
    Effects cmd
    -> SessionId
    -> BackendModel
    -> (( Id UserId, BackendUser ) -> ( BackendModel, cmd ))
    -> ( BackendModel, cmd )
adminAuthorization cmds sessionId model updateFunc =
    case checkLogin sessionId model of
        Just checkLogin_ ->
            if checkLogin_.isAdmin then
                updateFunc ( checkLogin_.userId, checkLogin_.user )

            else
                ( model, cmds.none )

        Nothing ->
            ( model, cmds.none )


isAdmin : BackendUser -> Bool
isAdmin user =
    EmailAddress.toString user.emailAddress == Env.adminEmailAddress


checkLogin : SessionId -> BackendModel -> Maybe { userId : Id UserId, user : BackendUser, isAdmin : Bool }
checkLogin sessionId model =
    case BiDict.get sessionId model.sessions of
        Just userId ->
            case Dict.get userId model.users of
                Just user ->
                    Just { userId = userId, user = user, isAdmin = isAdmin user }

                Nothing ->
                    Nothing

        Nothing ->
            Nothing


getGroup : Id GroupId -> BackendModel -> Maybe Group
getGroup groupId model =
    Dict.get groupId model.groups


getUser : Id UserId -> BackendModel -> Maybe BackendUser
getUser userId model =
    Dict.get userId model.users


getUserFromSessionId : SessionId -> BackendModel -> Maybe ( Id UserId, BackendUser )
getUserFromSessionId sessionId model =
    BiDict.get sessionId model.sessions
        |> Maybe.andThen (\userId -> getUser userId model |> Maybe.map (Tuple.pair userId))


loginEmailSubject : NonemptyString
loginEmailSubject =
    NonemptyString 'M' "eetdown login link"


loginEmailContent : Route -> Id LoginToken -> Maybe ( Id GroupId, EventId ) -> Email.Html.Html
loginEmailContent route loginToken maybeJoinEvent =
    let
        loginLink : String
        loginLink =
            loginEmailLink route loginToken maybeJoinEvent

        --_ =
        --    Debug.log "login" loginLink
    in
    Email.Html.div
        [ Email.Html.Attributes.padding "8px" ]
        [ Email.Html.a
            [ Email.Html.Attributes.href loginLink ]
            [ Email.Html.text "Click here to log in." ]
        , Email.Html.text " If you didn't request this email then it's safe to ignore it."
        ]


deleteAccountEmailSubject : NonemptyString
deleteAccountEmailSubject =
    NonemptyString 'C' "onfirm account deletion"


deleteAccountEmailContent : Id DeleteUserToken -> Email.Html.Html
deleteAccountEmailContent deleteUserToken =
    let
        deleteUserLink : String
        deleteUserLink =
            Env.domain ++ Route.encodeWithToken HomepageRoute (Route.DeleteUserToken deleteUserToken)

        --_ =
        --    Debug.log "delete user" deleteUserLink
    in
    Email.Html.div
        [ Email.Html.Attributes.padding "8px" ]
        [ Email.Html.a
            [ Email.Html.Attributes.href deleteUserLink ]
            [ Email.Html.text "Click here confirm you want to delete your account." ]
        , Email.Html.text " Remember, this action can not be reversed! If you didn't request this email then it's safe to ignore it."
        ]


eventReminderEmailSubject : GroupName -> Event -> Time.Zone -> NonemptyString
eventReminderEmailSubject groupName event timezone =
    let
        startTime =
            Event.startTime event

        hour =
            String.fromInt (Time.toHour timezone startTime)

        minute =
            Time.toMinute timezone startTime |> String.fromInt |> String.padLeft 2 '0'

        startText =
            hour
                ++ ":"
                ++ minute
                ++ (if timezone == Time.utc then
                        " (UTC)"

                    else
                        ""
                   )
    in
    String.Nonempty.append_
        (GroupName.toNonemptyString groupName)
        ("'s next event starts tomorrow, " ++ startText)


eventReminderEmailContent : Id GroupId -> GroupName -> Event -> Email.Html.Html
eventReminderEmailContent groupId groupName event =
    let
        groupRoute =
            Env.domain ++ Route.encode (Route.GroupRoute groupId groupName)
    in
    Email.Html.div
        [ Email.Html.Attributes.padding "8px" ]
        (Email.Html.b [] [ Event.name event |> EventName.toString |> Email.Html.text ]
            :: Email.Html.text " will be taking place "
            :: (case Event.eventType event of
                    Event.MeetOnline (Just meetingLink) ->
                        [ Email.Html.text "online tomorrow. The event will be accessible with this link "
                        , Email.Html.a
                            [ Email.Html.Attributes.href (Link.toString meetingLink) ]
                            [ Email.Html.text (Link.toString meetingLink) ]
                        , Email.Html.text ". "
                        ]

                    Event.MeetOnline Nothing ->
                        [ Email.Html.text "online tomorrow." ]

                    Event.MeetInPerson (Just address) ->
                        [ Email.Html.text (" in person tomorrow at " ++ Address.toString address ++ ".") ]

                    Event.MeetInPerson Nothing ->
                        [ Email.Html.text " in person tomorrow." ]
               )
            ++ [ Email.Html.br [] []
               , Email.Html.br [] []
               , Email.Html.a
                    [ Email.Html.Attributes.href groupRoute ]
                    [ Email.Html.text "Click here to go to their group page" ]
               ]
        )
