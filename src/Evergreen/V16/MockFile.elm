module Evergreen.V16.MockFile exposing (..)

import File


type File
    = RealFile File
    | MockFile String
