module Ui exposing
    ( button
    , css
    , dangerButton
    , dateInput
    , emailAddressText
    , enterKeyCode
    , error
    , filler
    , formError
    , headerButton
    , headerLink
    , hr
    , inputBackground
    , inputFocusClass
    , linkColor
    , multiline
    , numberInput
    , onEnter
    , radioGroup
    , routeLink
    , section
    , smallFontSize
    , submitButton
    , textInput
    , timeInput
    , title
    , titleFontSize
    )

import Element exposing (Element)
import Element.Background
import Element.Border
import Element.Font
import Element.Input
import Element.Region
import EmailAddress exposing (EmailAddress)
import Html exposing (Html)
import Html.Attributes
import Html.Events
import Id exposing (ButtonId(..), DateInputId(..), HtmlId, NumberInputId(..), RadioButtonId(..), TextInputId(..), TimeInputId(..))
import Json.Decode
import List.Nonempty exposing (Nonempty)
import Route exposing (Route)
import Time


css : Html msg
css =
    Html.node "style"
        []
        [ Html.text """


.linkFocus:focus {
    outline: solid #9bcbff !important;
}
        
        """
        ]


onEnter : msg -> Element.Attribute msg
onEnter msg =
    Html.Events.preventDefaultOn "keydown"
        (Json.Decode.field "keyCode" Json.Decode.int
            |> Json.Decode.andThen
                (\code ->
                    if code == enterKeyCode then
                        Json.Decode.succeed ( msg, True )

                    else
                        Json.Decode.fail "Not the enter key"
                )
        )
        |> Element.htmlAttribute


enterKeyCode =
    13


inputFocusClass : Element.Attribute msg
inputFocusClass =
    Element.htmlAttribute <| Html.Attributes.class "linkFocus"


headerButton : HtmlId ButtonId -> { onPress : msg, label : String } -> Element msg
headerButton htmlId { onPress, label } =
    Element.Input.button
        [ Element.mouseOver [ Element.Background.color <| Element.rgba 1 1 1 0.5 ]
        , Element.paddingXY 16 8
        , Element.Font.center
        , inputFocusClass
        , Id.htmlIdToString htmlId |> Html.Attributes.id |> Element.htmlAttribute
        ]
        { onPress = Just onPress
        , label = Element.text label
        }


headerLink : { route : Route, label : String } -> Element msg
headerLink { route, label } =
    Element.link
        [ Element.mouseOver [ Element.Background.color <| Element.rgba 1 1 1 0.5 ]
        , Element.paddingXY 16 8
        , Element.Font.center
        , inputFocusClass
        ]
        { url = Route.encode route
        , label = Element.text label
        }


emailAddressText : EmailAddress -> Element msg
emailAddressText emailAddress =
    Element.el
        [ Element.Font.bold ]
        (Element.text (EmailAddress.toString emailAddress))


routeLink : Route -> String -> Element msg
routeLink route label =
    Element.link
        [ Element.Font.color linkColor, inputFocusClass ]
        { url = Route.encode route, label = Element.text label }


section : String -> Element msg -> Element msg
section sectionTitle content =
    Element.column
        [ Element.spacing 8
        , Element.padding 8
        , Element.Border.rounded 4
        , inputBackground False
        ]
        [ Element.paragraph [ Element.Font.bold ] [ Element.text sectionTitle ]
        , content
        ]


button : HtmlId ButtonId -> { onPress : msg, label : String } -> Element msg
button htmlId { onPress, label } =
    Element.Input.button
        [ Element.Background.color <| Element.rgb 0.9 0.9 0.9
        , Element.Border.width 2
        , Element.Border.color <| Element.rgb 0.3 0.3 0.3
        , Element.padding 8
        , Element.Border.rounded 4
        , Element.Font.center
        , Element.width (Element.minimum 150 Element.shrink)
        , Id.htmlIdToString htmlId |> Html.Attributes.id |> Element.htmlAttribute
        ]
        { onPress = Just onPress
        , label = Element.text label
        }


linkColor : Element.Color
linkColor =
    Element.rgb 0.2 0.2 1


submitButton : HtmlId ButtonId -> Bool -> { onPress : msg, label : String } -> Element msg
submitButton htmlId isSubmitting { onPress, label } =
    Element.Input.button
        [ Element.Background.color <| Element.rgb 0.1 0.6 0.25
        , Element.padding 10
        , Element.Border.rounded 4
        , Element.Font.center
        , Element.Font.color <| Element.rgb 1 1 1
        , Id.htmlIdToString htmlId |> Html.Attributes.id |> Element.htmlAttribute
        ]
        { onPress = Just onPress
        , label =
            Element.el
                [ Element.width Element.fill
                , Element.paddingXY 30 0
                , if isSubmitting then
                    Element.inFront (Element.el [] (Element.text "⌛"))

                  else
                    Element.inFront Element.none
                ]
                (Element.text label)
        }


dangerButton : HtmlId ButtonId -> { onPress : msg, label : String } -> Element msg
dangerButton htmlId { onPress, label } =
    Element.Input.button
        [ Element.Background.color <| Element.rgb 0.9 0 0
        , Element.padding 10
        , Element.Border.rounded 4
        , Element.Font.center
        , Element.Font.color <| Element.rgb 1 1 1
        , Id.htmlIdToString htmlId |> Html.Attributes.id |> Element.htmlAttribute
        ]
        { onPress = Just onPress
        , label = Element.text label
        }


filler : Element.Length -> Element msg
filler length =
    Element.el [ Element.height length ] Element.none


titleFontSize : Element.Attr decorative msg
titleFontSize =
    Element.Font.size 32


smallFontSize : Element.Attr decorative msg
smallFontSize =
    Element.Font.size 16


title : String -> Element msg
title text =
    Element.paragraph [ titleFontSize, Element.Region.heading 1 ] [ Element.text text ]


hr : Element msg
hr =
    Element.el
        [ Element.padding 8, Element.width Element.fill ]
        (Element.el
            [ Element.width Element.fill
            , Element.height (Element.px 2)
            , Element.Background.color <| Element.rgb 0.4 0.4 0.4
            ]
            Element.none
        )


error : String -> Element msg
error errorMessage =
    Element.paragraph
        [ Element.paddingEach { left = 4, right = 4, top = 4, bottom = 0 }
        , Element.Font.color <| Element.rgb 0.9 0.2 0.2
        , Element.Font.size 16
        ]
        [ Element.text errorMessage ]


formError : String -> Element msg
formError errorMessage =
    Element.paragraph
        [ Element.Font.color <| Element.rgb 0.9 0.2 0.2
        ]
        [ Element.text errorMessage ]


radioGroup : (a -> HtmlId RadioButtonId) -> (a -> msg) -> Nonempty a -> Maybe a -> (a -> String) -> Maybe String -> Element msg
radioGroup htmlId onSelect options selected optionToLabel maybeError =
    let
        optionsView =
            List.Nonempty.map
                (\value ->
                    Element.Input.button
                        [ Element.width Element.fill
                        , Element.paddingEach { left = 32, right = 8, top = 8, bottom = 8 }
                        , htmlId value |> Id.htmlIdToString |> Html.Attributes.id |> Element.htmlAttribute
                        ]
                        { onPress = Just (onSelect value)
                        , label =
                            optionToLabel value
                                |> Element.text
                                |> List.singleton
                                |> Element.paragraph
                                    [ if Just value == selected then
                                        Element.onLeft <| Element.text "✅"

                                      else
                                        Element.onLeft <| Element.text "☐"
                                    , Element.paddingXY 8 0
                                    ]
                        }
                )
                options
                |> List.Nonempty.toList
    in
    optionsView
        ++ [ Maybe.map error maybeError |> Maybe.withDefault Element.none ]
        |> Element.column
            [ inputBackground (maybeError /= Nothing)
            , Element.Border.rounded 4
            , Element.padding 8
            ]


inputBackground : Bool -> Element.Attr decorative msg
inputBackground hasError =
    Element.Background.color <|
        if hasError then
            Element.rgb 1 0.9059 0.9059

        else
            Element.rgb 0.94 0.94 0.94


textInput : HtmlId TextInputId -> (String -> msg) -> String -> String -> Maybe String -> Element msg
textInput htmlId onChange text labelText maybeError =
    Element.column
        [ Element.width Element.fill
        , inputBackground (maybeError /= Nothing)
        , Element.paddingEach { left = 8, right = 8, top = 8, bottom = 8 }
        , Element.Border.rounded 4
        ]
        [ Element.Input.text
            [ Element.width Element.fill
            , Id.htmlIdToString htmlId |> Html.Attributes.id |> Element.htmlAttribute
            ]
            { text = text
            , onChange = onChange
            , placeholder = Nothing
            , label =
                Element.Input.labelAbove
                    [ Element.paddingXY 4 0 ]
                    (Element.paragraph [] [ Element.text labelText ])
            }
        , Maybe.map error maybeError |> Maybe.withDefault Element.none
        ]


multiline : HtmlId TextInputId -> (String -> msg) -> String -> String -> Maybe String -> Element msg
multiline htmlId onChange text labelText maybeError =
    Element.column
        [ Element.width Element.fill
        , inputBackground (maybeError /= Nothing)
        , Element.paddingEach { left = 8, right = 8, top = 8, bottom = 8 }
        , Element.Border.rounded 4
        ]
        [ Element.Input.multiline
            [ Element.width Element.fill
            , Element.height (Element.px 200)
            , Id.htmlIdToString htmlId |> Html.Attributes.id |> Element.htmlAttribute
            ]
            { text = text
            , onChange = onChange
            , placeholder = Nothing
            , label =
                Element.Input.labelAbove
                    [ Element.paddingXY 4 0 ]
                    (Element.paragraph [] [ Element.text labelText ])
            , spellcheck = True
            }
        , Maybe.map error maybeError |> Maybe.withDefault Element.none
        ]


numberInput : HtmlId NumberInputId -> (String -> msg) -> String -> Element msg
numberInput htmlId onChange value =
    Element.html <|
        Html.input
            [ Html.Attributes.type_ "number"
            , Html.Events.onInput onChange
            , Id.htmlIdToString htmlId |> Html.Attributes.id
            , Html.Attributes.value value
            ]
            []


timeInput : HtmlId TimeInputId -> (String -> msg) -> String -> Element msg
timeInput htmlId onChange time =
    Element.html <|
        Html.input
            [ Html.Attributes.type_ "time"
            , Html.Events.onInput onChange
            , Html.Attributes.value time
            , Id.htmlIdToString htmlId |> Html.Attributes.id
            ]
            []


dateInput : HtmlId DateInputId -> (String -> msg) -> Time.Posix -> Time.Zone -> String -> Element msg
dateInput htmlId onChange minDateTime timeZone date =
    Element.html <|
        Html.input
            [ Html.Attributes.type_ "date"
            , Html.Attributes.min (datestamp minDateTime timeZone)
            , Html.Events.onInput onChange
            , Html.Attributes.value date
            , Id.htmlIdToString htmlId |> Html.Attributes.id
            ]
            []


datestamp : Time.Posix -> Time.Zone -> String
datestamp time timezone =
    let
        monthValue =
            case Time.toMonth timezone time of
                Time.Jan ->
                    "01"

                Time.Feb ->
                    "02"

                Time.Mar ->
                    "03"

                Time.Apr ->
                    "04"

                Time.May ->
                    "05"

                Time.Jun ->
                    "06"

                Time.Jul ->
                    "07"

                Time.Aug ->
                    "08"

                Time.Sep ->
                    "09"

                Time.Oct ->
                    "10"

                Time.Nov ->
                    "11"

                Time.Dec ->
                    "12"
    in
    String.fromInt (Time.toYear timezone time)
        ++ "-"
        ++ monthValue
        ++ "-"
        ++ String.padLeft 2 '0' (String.fromInt (Time.toDay timezone time))
