module Unsafe exposing (..)

import Description exposing (Description)
import EmailAddress exposing (EmailAddress)
import EventDuration exposing (EventDuration)
import EventName exposing (EventName)
import GroupName exposing (GroupName)
import Link exposing (Link)
import Url exposing (Url)


url : String -> Url
url urlText =
    case Url.fromString urlText of
        Just url_ ->
            url_

        Nothing ->
            Debug.todo ("Invalid url " ++ urlText)


emailAddress : String -> EmailAddress
emailAddress text =
    case EmailAddress.fromString text of
        Just address ->
            address

        Nothing ->
            Debug.todo ("Invalid email address " ++ text)


groupName : String -> GroupName
groupName name =
    case GroupName.fromString name of
        Ok value ->
            value

        Err _ ->
            Debug.todo ("Invalid group name " ++ name)


eventName : String -> EventName
eventName name =
    case EventName.fromString name of
        Ok value ->
            value

        Err _ ->
            Debug.todo ("Invalid event name " ++ name)


description : String -> Description
description name =
    case Description.fromString name of
        Ok value ->
            value

        Err _ ->
            Debug.todo ("Invalid description " ++ name)


link : String -> Link
link text =
    case Link.fromString text of
        Just value ->
            value

        Nothing ->
            Debug.todo ("Invalid link " ++ text)


eventDuration : Int -> EventDuration
eventDuration minutes =
    case EventDuration.fromMinutes minutes of
        Ok duration ->
            duration

        Err _ ->
            Debug.todo ("Invalid event duration " ++ String.fromInt minutes)