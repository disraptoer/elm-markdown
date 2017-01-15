import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (onInput)
import Markdown
import Markdown.Config exposing (defaultElements, defaultOptions)



main : Program Never Model Msg
main =
    Html.program
        { init = init ! []
        , view = view
        , update = update
        , subscriptions = \_ -> Sub.none
        }


type alias Model =
    { textarea : String
    }


init : Model
init =
    { textarea = initTextarea
    }


initTextarea : String
initTextarea = """
All links starting with `http://www.google.com.br` will not have a `target="_blank"` attribute.

[This link](http://elm-lang.org/docs "Elm docs") have a `target="_blank"` attribute, because starts with `http://elm-lang.org/`.

[This link](http://www.google.com.br "Google") does not.
"""


type Msg
    = TextAreaInput String
    | Markdown



update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        TextAreaInput str ->
            { model | textarea = str } ! []

        Markdown ->
            model ! []


view : Model -> Html Msg
view model =
    div [ containerStyle ]
        [ h1 []
            [ a
                [ href "http://package.elm-lang.org/packages/pablohirafuji/elm-markdown/latest" ]
                [ text "Elm Markdown" ]
            ]
        , h2 []
            [ text "Custom link target example / "
            , a [ href "https://github.com/pablohirafuji/elm-markdown/blob/master/examples/CustomLinkTag.elm" ]
                [ text "Code" ]
            ]
        , div [ displayFlex ]
            [ div [ width50Style ]
                [ textarea
                    [ onInput TextAreaInput
                    , defaultValue model.textarea
                    , textareaStyle
                    ] []
                ]
            , Html.map (always Markdown)
                <| div [ width50Style ]
                <| Markdown.customHtml
                    Markdown.Config.defaultOptions
                    customElements
                    model.textarea
            ]
        ]

customElements : Markdown.Config.Elements
customElements =
    { defaultElements
        | link = customLinkElement
    }


customLinkElement : Markdown.Config.Link -> List (Html Never) -> Html Never
customLinkElement link =
    let
        additionalAttrs : List (Html.Attribute Never)
        additionalAttrs =
            if String.startsWith "http://www.google.com.br" link.url then
                []

            else
                [ target "_blank", rel "noopener noreferrer" ]


    in
        a <|
            [ href link.url
            , title (Maybe.withDefault "" link.title)
            ] ++ additionalAttrs
            


-- Styles


containerStyle : Attribute msg
containerStyle =
    style
        [ ("font-family", "sans-serif")
        , ("color", "rgba(0,0,0,0.8)")
        , ("margin", "0 auto")
        , ("padding", "20px")
        , ("max-width", "1080px")
        ]


displayFlex : Attribute msg
displayFlex =
    style [ ("display", "flex") ]


width50Style : Attribute msg
width50Style =
    style [ ("width", "50%") ]


textareaStyle : Attribute msg
textareaStyle =
    style
        [ ("width", "90%")
        , ("height", "400px")
        ]
