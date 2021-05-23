module ProfileImage exposing (ProfileImage, customImage, defaultImage, getCustomImageUrl, image, smallImage)

import Element exposing (Element)
import Element.Border
import Ui


type ProfileImage
    = DefaultImage
    | CustomImage String


type Error
    = InvalidDataUrlPrefix
    | StringIsTooLong


defaultImage : ProfileImage
defaultImage =
    DefaultImage


customImage : String -> Result Error ProfileImage
customImage data =
    if String.length data > 100000 then
        Err StringIsTooLong

    else if String.startsWith "data:image/png;base64," data |> not then
        Err InvalidDataUrlPrefix

    else
        CustomImage data |> Ok


size : number
size =
    128


getCustomImageUrl : ProfileImage -> Maybe String
getCustomImageUrl profileImage =
    case profileImage of
        DefaultImage ->
            Nothing

        CustomImage dataUrl ->
            Just dataUrl


image : ProfileImage -> Element msg
image profileImage =
    Element.image
        [ Element.width (Element.px size)
        , Element.height (Element.px size)
        , Element.Border.rounded 9999
        , Element.clip
        , Ui.inputBackground False
        ]
        { src =
            case profileImage of
                DefaultImage ->
                    "/default-profile.png"

                CustomImage dataUrl ->
                    dataUrl
        , description = "Profile image"
        }


smallImage : ProfileImage -> Element msg
smallImage profileImage =
    Element.image
        [ Element.width (Element.px <| size // 2)
        , Element.height (Element.px <| size // 2)
        , Element.Border.rounded 9999
        , Element.clip
        , Ui.inputBackground False
        ]
        { src =
            case profileImage of
                DefaultImage ->
                    "/default-profile.png"

                CustomImage dataUrl ->
                    dataUrl
        , description = "Profile image"
        }