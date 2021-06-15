module Evergreen.V9.CreateGroupForm exposing (..)

import Evergreen.V9.Description
import Evergreen.V9.Group
import Evergreen.V9.GroupName


type alias Form =
    { pressedSubmit : Bool
    , name : String
    , description : String
    , visibility : Maybe Evergreen.V9.Group.GroupVisibility
    }


type alias GroupFormValidated =
    { name : Evergreen.V9.GroupName.GroupName
    , description : Evergreen.V9.Description.Description
    , visibility : Evergreen.V9.Group.GroupVisibility
    }


type CreateGroupError
    = GroupNameAlreadyInUse


type Model
    = Editting Form
    | Submitting GroupFormValidated
    | SubmitFailed CreateGroupError Form


type Msg
    = FormChanged Form
    | PressedSubmit
    | PressedClear
