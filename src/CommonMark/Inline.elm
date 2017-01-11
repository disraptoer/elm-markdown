module CommonMark.Inline exposing (..)


import Dict exposing (Dict)
import Html exposing (..)
import Html.Attributes exposing (href, title, alt, src)
import Http exposing (encodeUri)
import Regex exposing (Regex)



----- Match


type Match
    = Match MatchModel


type alias MatchModel =
    { type_   : Type
    , start   : Int
    , end     : Int
    , rawText : String
    , text    : String
    , matches : List Match
    }


normalMatch : String -> Match
normalMatch text =
    Match
        { type_   = Normal
        , start   = 0
        , end     = 0
        , rawText = text
        , text    = replaceEscapable text
        , matches = []
        }


type Type
    = Normal
    | HardBreak
    | Code
    | Emphasis Int -- Tag length
    | Link ( String, Maybe String) -- ( Url, Maybe Title )
    | Image ( String, Maybe String) -- ( Src, Maybe Title )


regexes : List ( Type, Regex )
regexes =
    [ ( HardBreak, hardBreakRegex )
    ]


hardBreakRegex : Regex
hardBreakRegex =
    Regex.regex " {2,}\\n|\\\\\\n"


whiteSpaceChars : String
whiteSpaceChars =
    " \\t\\f\\v\\r\\n"


cleanWhitespaces : String -> String
cleanWhitespaces =
    String.trim
        >> Regex.replace Regex.All
            (Regex.regex ("[" ++ whiteSpaceChars ++ "]+"))
            (\_ -> " ")


escapableRegex : Regex
escapableRegex =
    Regex.regex "(\\\\+)([!\"#$%&\\'()*+,./:;<=>?@[\\\\\\]^_`{|}~-])"


replaceEscapable : String -> String
replaceEscapable =
    Regex.replace Regex.All escapableRegex
        (\regexMatch ->
            case regexMatch.submatches of
                Just backslashes :: Just escapedStr :: _ ->
                    String.repeat
                        (String.length backslashes // 2)
                        "\\" ++ escapedStr

                _ ->
                    regexMatch.match
        )


-- Decode the following chars: ;,/?:@&=+$#%
decodeUrlRegex : Regex
decodeUrlRegex =
    Regex.regex "%(?:3B|2C|2F|3F|3A|40|26|3D|2B|24|23|25)"


encodeUrl : String -> String
encodeUrl =
    Http.encodeUri
        >> Regex.replace Regex.All decodeUrlRegex
            (\match ->
                Http.decodeUri match.match
                    |> Maybe.withDefault match.match
            )


containSpace : String -> Bool
containSpace str =
    Regex.contains
        (Regex.regex "\\s")
        str


containPuntuaction : String -> Bool
containPuntuaction str =
    Regex.contains
        (Regex.regex "[!-#%-\\*,-/:;\\?@\\[-\\]_\\{\\}]")
        str


returnFirstJust : List (Maybe a) -> Maybe a
returnFirstJust maybes =
    let
        process : Maybe a -> Maybe a -> Maybe a
        process a maybeFound =
            case maybeFound of
                Just found -> Just found
                Nothing -> a

    in
        List.foldl process Nothing maybes


ifNothing : Maybe a -> Maybe a -> Maybe a
ifNothing maybe maybe_ =
    if maybe_ == Nothing then
        maybe

    else
        maybe_


findMatches : References -> String -> List Match
findMatches refs rawText =
    findRegexesMatches regexes rawText
        |> (++) (.matches (lexer (initLexerModel refs rawText)))


findRegexesMatches : List ( Type, Regex ) -> String -> List Match
findRegexesMatches regexes rawText =
    List.map (findRegexMatch rawText) regexes
        |> List.concat


findRegexMatch : String -> ( Type, Regex ) -> List Match
findRegexMatch rawText ( type_, regex ) =
    Regex.find Regex.All regex rawText
        |> List.map (Match << matchModelFromRegex type_)


matchModelFromRegex : Type -> Regex.Match -> MatchModel
matchModelFromRegex type_ regexMatch =
    { type_   = type_
    , start   = regexMatch.index
    , end     = regexMatch.index + String.length regexMatch.match
    , rawText = regexMatch.match
    , text    = regexMatch.match
    , matches = []
    }


organizeMatches : List Match -> List Match
organizeMatches =
    List.sortBy (\(Match match) -> match.start)
        >> List.foldl organizeMatch []
        >> List.map
            (\(Match match) -> Match
                { match | matches =
                    organizeMatches match.matches
                }
            )


organizeMatch : Match -> List Match -> List Match
organizeMatch (Match match) matches =
    case matches of
        [] ->
            [ Match match ]

        Match prevMatch :: matchesTail ->
            -- New Match
            if prevMatch.end <= match.start then
                Match match :: matches

            -- Inside previous Match
            else if prevMatch.start < match.start
                && prevMatch.end > match.end then
                    addChild prevMatch match :: matchesTail

            -- Overlaping previous Match
            else
                matches


addChild : MatchModel -> MatchModel -> Match
addChild parentMatch childMatch =
    let
        reduction : Int
        reduction =
            case parentMatch.type_ of
                Emphasis length ->
                    parentMatch.start + length

                _ ->
                    parentMatch.start


        updtChildMatch : MatchModel
        updtChildMatch =
            { childMatch
                | start = childMatch.start - reduction
                , end = childMatch.end - reduction
            }


    in
        Match { parentMatch | matches =
            Match updtChildMatch :: parentMatch.matches
        }


parseNormalMatches : String -> List Match -> List Match -> List Match
parseNormalMatches rawText parsedMatches matches =
    case matches of
        [] ->
            case parsedMatches of
                [] ->
                    -- No text to parse
                    if String.isEmpty rawText then
                        []

                    -- No match found
                    else
                        [ normalMatch rawText ]


                -- Add initial normal match
                Match matchModel :: _ ->
                    if matchModel.start > 0 then
                        normalMatch (String.left (matchModel.start) rawText)
                            :: parsedMatches

                    else
                        parsedMatches


        match :: matchesTail ->
            parseNormalMatches rawText
                (parseNormalMatch rawText match parsedMatches)
                matchesTail


parseNormalMatch : String -> Match -> List Match -> List Match
parseNormalMatch rawText (Match matchModel) parsedMatches =
    let
        -- TODO se for image ou link, tem que achar os matchs
        -- Ou fazer sso quando parsar link ou imagem
        updtMatch : Match
        updtMatch =
            Match { matchModel |
                matches =
                    parseNormalMatches matchModel.text [] matchModel.matches
            }

    in
        case parsedMatches of
            [] ->
                -- Add final normal match
                let
                    finalStr =
                        String.dropLeft matchModel.end rawText

                in
                    if String.isEmpty finalStr then
                        [ updtMatch ]

                    else
                        [ updtMatch
                        , normalMatch finalStr
                        ]


            Match matchHead :: matchesTail ->
                if matchHead.type_ == Normal then
                    updtMatch :: parsedMatches

                -- New Match
                else if matchModel.end == matchHead.start then
                    updtMatch :: parsedMatches

                -- New Match and add in between unmatched string
                else if matchModel.end < matchHead.start then
                    updtMatch
                        :: normalMatch (String.slice matchModel.end matchHead.start rawText)
                        :: parsedMatches

                -- Overlaping or inside previous Match
                else
                    parsedMatches



----- Lexer


type alias LexerModel =
    { rawText : String
    , remainText : String
    , lastChar : Maybe Char
    , isEscaped : Bool
    , tokens : List Token
    , index : Int
    , matches : List Match
    , refs : References
    }


initLexerModel : References -> String -> LexerModel
initLexerModel refs rawText  =
    { rawText = rawText
    , remainText = rawText
    , lastChar = Nothing
    , isEscaped = False
    , tokens = []
    , index = 0
    , matches = []
    , refs = refs
    }


type alias Token =
    { index : Int
    , length : Int
    , meaning : Meaning
    }


type Meaning
    = EmphasisTag Char
    | LinkOpen
    | ImageOpen


lexer : LexerModel -> LexerModel
lexer model =
    case String.uncons model.remainText of
        Nothing ->
            model

        Just ( char, remainTextTail ) ->
            let
                noOpModel =
                    { model
                        | remainText = remainTextTail
                        , lastChar = Just char
                        , index = model.index + 1
                        , isEscaped = False
                    }

            in
                if model.isEscaped then
                    lexer noOpModel

                else
                    if char == '*' || char == '_' then
                        emphasisTagFound model
                            |> Maybe.withDefault noOpModel
                            |> lexer

                    else if char == '`' then
                        codeTagFound model
                            |> Maybe.withDefault noOpModel
                            |> lexer

                    else if char == '[' then
                        linkTagFound model
                            |> Maybe.withDefault noOpModel
                            |> lexer

                    else if char == '!' then
                        imageTagFound model
                            |> Maybe.withDefault noOpModel
                            |> lexer

                    else if char == '<' then
                        autoLinkTagFound model
                            |> Maybe.withDefault noOpModel
                            |> lexer

                    else if char == '\\' then
                        lexer { noOpModel | isEscaped = True }

                    else
                        lexer noOpModel



-- Code Span


codeTagFound : LexerModel -> Maybe LexerModel
codeTagFound model =
    let
        openRegex : Regex
        openRegex =
            Regex.regex "^(`+)"


        closeRegex : Int -> Regex
        closeRegex length =
            Regex.regex ("^([\\s\\S]*?[^`])(`{" ++ toString length ++ "})([^`]|$)")


        extractOpenTagLength : String -> Maybe Int
        extractOpenTagLength =
            Regex.find (Regex.AtMost 1) openRegex
                >> List.head
                >> Maybe.map (.match >> String.length)


        toMatch : ( String, String ) -> Match
        toMatch ( code, tag ) =
            let
                rawText = tag ++ code ++ tag

            in
                { type_   = Code
                , start   = model.index
                , end     = model.index + String.length rawText
                , rawText = rawText
                , text    = cleanWhitespaces code
                , matches = []
                } |> Match


        verifyCloseTag : String -> Int -> LexerModel
        verifyCloseTag remainText tagLength =
            let
                remainTextWithoutOpenTag : String
                remainTextWithoutOpenTag =
                    String.dropLeft tagLength remainText


                noMatchLexerModel : LexerModel
                noMatchLexerModel =
                    { model
                        | remainText = remainTextWithoutOpenTag
                        , index = model.index + tagLength
                        , lastChar = Just '`'
                    }


                maybeCloseRegexMatch : String -> Maybe Regex.Match
                maybeCloseRegexMatch =
                    Regex.find (Regex.AtMost 1) (closeRegex tagLength)
                        >> List.head


                extractCodeAndCloseTag : Regex.Match -> LexerModel
                extractCodeAndCloseTag regexMatch =
                    case regexMatch.submatches of
                        Just code :: Just closeTag :: _ ->
                            ( code, closeTag )
                                |> toMatch
                                |> updateLexerModel model

                        _ ->
                            noMatchLexerModel


            in
                remainTextWithoutOpenTag
                    |> maybeCloseRegexMatch
                    |> Maybe.map extractCodeAndCloseTag
                    |> Maybe.withDefault noMatchLexerModel


    in
        model.remainText
            |> extractOpenTagLength
            |> Maybe.map (verifyCloseTag model.remainText)



-- Link


type alias References =
    Dict String ( String, Maybe String ) -- Label ( Url, Maybe Title )


type alias LinkMatch =
    { matchLength : Int
    , inside : String
    , url : String
    , maybeTitle : Maybe String
    }


insideRegex : String
insideRegex =
    "[^\\[\\]\\\\]*(?:\\\\.[^\\[\\]\\\\]*)*"


titleRegex : String
titleRegex =
    "(?:[" ++ whiteSpaceChars ++ "]+(?:'([^'\\\\]*(?:\\\\.[^'\\\\]*)*)'|\"([^\"\\\\]*(?:\\\\.[^\"\\\\]*)*)\"|\\(([^\\)\\\\]*(?:\\\\.[^\\)\\\\]*)*)\\)))?"


hrefRegex : String
hrefRegex =
    "\\s*(?:<([^<>"
    ++ whiteSpaceChars ++ "]*)>|([^"
    ++ whiteSpaceChars ++ "\\(\\)\\\\]*(?:\\\\.[^\\(\\)\\\\]*)*))"


urlTitleRegex : String
urlTitleRegex =
    "\\[(" ++ insideRegex
        ++ ")\\]\\("
        ++ hrefRegex
        ++ titleRegex
        ++ "\\s*\\)"


refRegex : String
refRegex =
    "\\[(" ++ insideRegex
        ++ ")\\](?:\\[\\s*("
        ++ insideRegex
        ++ ")\\s*\\])?"


linkRegex : Regex
linkRegex =
    Regex.regex ("^" ++ urlTitleRegex)


refLinkRegex : Regex
refLinkRegex =
    Regex.regex ("^" ++ refRegex)


extractUrlTitleRegex : Regex.Match -> Maybe LinkMatch
extractUrlTitleRegex regexMatch =
    case regexMatch.submatches of
        Just rawText
            :: maybeRawUrlAB -- with angle brackets: <http://url.com>
            :: maybeRawUrlW -- without angle brackets : http://url.com
            :: maybeTitleSQ -- with single quotes: 'title'
            :: maybeTitleDQ -- with double quotes: "title"
            :: maybeTitleP -- with parenthesis: (title)
            :: _ ->
                let
                    maybeRawUrl : Maybe String
                    maybeRawUrl =
                        returnFirstJust [ maybeRawUrlAB, maybeRawUrlW ]


                    toReturn : String -> LinkMatch
                    toReturn rawUrl =
                        { matchLength = String.length regexMatch.match
                        , inside = rawText
                        , url = rawUrl
                        , maybeTitle =
                            returnFirstJust
                                [ maybeTitleSQ
                                , maybeTitleDQ
                                , maybeTitleP
                                ]
                        }

                in
                    maybeRawUrl
                        |> Maybe.map toReturn
                    

        _ ->
            Nothing


extractRefRegex : References -> Regex.Match -> Maybe LinkMatch
extractRefRegex refs regexMatch =
    case regexMatch.submatches of
        Just label :: maybeLabel :: _ ->
            let
                refLabel : String
                refLabel =
                    case maybeLabel of
                        Nothing -> label
                        Just "" -> label
                        Just ref -> ref


                maybeRefItem : Maybe ( String, Maybe String )
                maybeRefItem =
                    Dict.get (prepareRefLabel refLabel) refs


                toReturn : ( String, Maybe String ) -> LinkMatch
                toReturn ( rawUrl, maybeTitle ) =
                    { matchLength = String.length regexMatch.match
                    , inside = label
                    , url = rawUrl
                    , maybeTitle = maybeTitle
                    }

            in
                maybeRefItem
                    |> Maybe.map toReturn
                    

        _ ->
            Nothing


prepareRefLabel : String -> String
prepareRefLabel =
    cleanWhitespaces
        >> String.toLower


-- TODO code backtick have precedence over link - how to do?
-- TODO: Parsar título quando imprimir
linkTagFound : LexerModel -> Maybe LexerModel
linkTagFound model =
    let
        linkMatchToMatch : LexerModel -> LinkMatch -> Match
        linkMatchToMatch model { matchLength, inside, url, maybeTitle } =
            { type_   = Link
                            ( encodeUrl (replaceEscapable url)
                            , Maybe.map replaceEscapable maybeTitle ) 
            , start   = model.index
            , end     = model.index + matchLength
            , rawText = inside
            , text    = inside
            , matches = findMatches Dict.empty inside
            } |> Match


        applyLinkRegex : String -> Maybe LinkMatch
        applyLinkRegex =
            Regex.find (Regex.AtMost 1) linkRegex
                >> List.head
                >> Maybe.andThen extractUrlTitleRegex


        applyRefLinkRegex : String -> Maybe LinkMatch
        applyRefLinkRegex =
            Regex.find (Regex.AtMost 1) refLinkRegex
                >> List.head
                >> Maybe.andThen (extractRefRegex model.refs)


    in
        model.remainText
            |> applyLinkRegex
            |> ifNothing (applyRefLinkRegex model.remainText)
            |> Maybe.map (linkMatchToMatch model)
            |> Maybe.map (updateLexerModel model)



-- Image


imageRegex : Regex
imageRegex =
    Regex.regex ("^!" ++ urlTitleRegex)


refImageRegex : Regex
refImageRegex =
    Regex.regex ("^!" ++ refRegex)


imageTagFound : LexerModel -> Maybe LexerModel
imageTagFound model =
    let
        linkMatchToMatch : LinkMatch -> Match
        linkMatchToMatch { matchLength, inside, url, maybeTitle } =
            { type_   = Image
                            ( replaceEscapable url
                            , Maybe.map replaceEscapable maybeTitle )
            , start   = model.index
            , end     = model.index + matchLength
            , rawText = inside
            , text    = inside
            , matches = []
            } |> Match


        applyImageRegex : String -> Maybe LinkMatch
        applyImageRegex =
            Regex.find (Regex.AtMost 1) imageRegex
                >> List.head
                >> Maybe.andThen extractUrlTitleRegex


        applyRefImageRegex : String -> Maybe LinkMatch
        applyRefImageRegex =
            Regex.find (Regex.AtMost 1) refImageRegex
                >> List.head
                >> Maybe.andThen (extractRefRegex model.refs)


    in
        model.remainText
            |> applyImageRegex
            |> ifNothing (applyRefImageRegex model.remainText)
            |> Maybe.map linkMatchToMatch
            |> Maybe.map (updateLexerModel model)



-- Autolink


-- From http://spec.commonmark.org/dingus/commonmark.js
emailAutoLinkRegex : Regex
emailAutoLinkRegex =
    Regex.regex "^<([a-zA-Z0-9.!#$%&'*+\\/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*)>"


-- From http://spec.commonmark.org/dingus/commonmark.js
autoLinkRegex : Regex
autoLinkRegex =
    Regex.regex "^<([A-Za-z][A-Za-z0-9.+-]{1,31}:[^<>\x00-\x20]*)>"


autoLinkTagFound : LexerModel -> Maybe LexerModel
autoLinkTagFound model =
    let
        linkMatchToMatch : LexerModel -> LinkMatch -> Match
        linkMatchToMatch model { matchLength, inside, url, maybeTitle } =
            { type_   = Link ( url, maybeTitle ) 
            , start   = model.index
            , end     = model.index + matchLength
            , rawText = inside
            , text    = inside
            , matches = []
            } |> Match

        extractRegex : Regex.Match -> Maybe LinkMatch
        extractRegex regexMatch =
            regexMatch.submatches
                |> List.head
                |> Maybe.withDefault Nothing
                |> Maybe.map
                    (\url ->
                        { matchLength =
                            String.length regexMatch.match
                        , inside = url
                        , url = encodeUrl url
                        , maybeTitle = Nothing
                        }
                    )
            

        applyEmailAutoLinkRegex : String -> Maybe LinkMatch
        applyEmailAutoLinkRegex =
            Regex.find (Regex.AtMost 1) emailAutoLinkRegex
                >> List.head
                >> Maybe.andThen extractRegex
                >> Maybe.map
                    (\linkMatch ->
                        { linkMatch
                            | url = "mailto:" ++ linkMatch.url
                        }
                    )


        applyAutoLinkRegex : String -> Maybe LinkMatch
        applyAutoLinkRegex =
            Regex.find (Regex.AtMost 1) autoLinkRegex
                >> List.head
                >> Maybe.andThen extractRegex


    in
        model.remainText
            |> applyEmailAutoLinkRegex
            |> ifNothing (applyAutoLinkRegex model.remainText)
            |> Maybe.map (linkMatchToMatch model)
            |> Maybe.map (updateLexerModel model)



-- Emphasis


type alias EmphasisMatchToken =
    { openToken : Token
    , closeToken : Token
    , tokens : List Token
    , isMultipleOf3 : Bool
    }


emphasisTagFound : LexerModel -> Maybe LexerModel
emphasisTagFound model =
    let
        regexMatchToTuple : List Regex.Match -> ( Maybe String, Maybe String )
        regexMatchToTuple matches =
            case matches of
                match :: _ ->
                    case match.submatches of
                        maybeEmSequence :: maybeNextChar :: _ ->
                            ( maybeEmSequence, maybeNextChar )

                        _ ->
                            ( Nothing, Nothing )

                _ ->
                    ( Nothing, Nothing )


        emSequenceRegex : Regex
        emSequenceRegex =
            Regex.regex "^(\\*+|_+)(.)?"


        ( maybeEmSequence, maybeNextString) =
            Regex.find (Regex.AtMost 1) emSequenceRegex model.remainText
                |> regexMatchToTuple


        fringeRank : String -> Int
        fringeRank string =
            if containSpace string then 0
            else if containPuntuaction string then 1
            else 2

        leftFringeRank : Int
        leftFringeRank =
            model.lastChar
                |> Maybe.map (fringeRank << String.fromChar)
                |> Maybe.withDefault 0


        rightFringeRank : Int
        rightFringeRank =
            maybeNextString
                |> Maybe.map fringeRank
                |> Maybe.withDefault 0


        processEmSequence : String -> LexerModel
        processEmSequence emSequence =
            let
                emSequenceLength : Int
                emSequenceLength =
                    String.length emSequence


                remainText : String
                remainText =
                    model.remainText
                        |> String.dropLeft emSequenceLength


                lastChar : Maybe Char
                lastChar =
                    String.uncons emSequence
                        |> Maybe.map Tuple.first


                char : Char
                char =
                    lastChar
                        |> Maybe.withDefault '*'


                index : Int
                index =
                    model.index + emSequenceLength


                emToken : Token
                emToken =
                    { index = model.index
                    , length = emSequenceLength
                    , meaning = EmphasisTag char
                    }


                updtModel : LexerModel
                updtModel =
                    { model
                        | remainText = remainText
                        , lastChar = lastChar
                        , index = index
                    }


                addMatch : LexerModel -> Token -> EmphasisMatchToken -> LexerModel
                addMatch model rawCloseToken { openToken, closeToken, tokens } =
                    let
                        updtModel : LexerModel
                        updtModel =
                            { model
                                | tokens = tokens
                                , matches =
                                    tokenToMatch
                                        model.rawText
                                        openToken
                                        closeToken
                                            :: model.matches
                            }


                        remainLength : Int
                        remainLength =
                            rawCloseToken.length - closeToken.length


                        updtCloseToken : Token
                        updtCloseToken =
                            { rawCloseToken
                                | index  = closeToken.index + closeToken.length
                                , length = remainLength
                            }


                    in
                        -- Still has closing token
                        if remainLength > 0 then
                            case retrieveToken updtCloseToken tokens of
                                Just retrTokens ->
                                    addMatch updtModel updtCloseToken retrTokens

                                Nothing ->
                                    updtModel


                        else
                            updtModel


            in
                -- Maybe close or opening tag
                if leftFringeRank == rightFringeRank then
                    -- If 1) is not surrounded by whitespace and
                    --    2) is not '_' or is surronded by puntuaction
                    -- is a close or opening tag
                    if rightFringeRank /= 0
                        && (char /= '_' || rightFringeRank == 1) then
                            -- Search for opening tag and add
                            -- match if the sum of lengths
                            -- is not multiple of 3, otherwise add
                            -- opening tag
                            case retrieveToken emToken model.tokens of
                                Just retrToken ->
                                    if retrToken.isMultipleOf3 then
                                        { updtModel |
                                            tokens = emToken :: model.tokens
                                        }

                                    else
                                        addMatch updtModel emToken retrToken


                                Nothing ->
                                    { updtModel |
                                        tokens = emToken :: model.tokens
                                    }


                    else
                        updtModel


                -- Opening tag
                else if leftFringeRank < rightFringeRank then
                    { updtModel |
                        tokens = emToken :: model.tokens
                    }


                -- CLosing tag
                else
                    case retrieveToken emToken model.tokens of
                        Just retrToken ->
                            addMatch updtModel emToken retrToken


                        Nothing ->
                            updtModel


    in
        maybeEmSequence
            |> Maybe.map processEmSequence


retrieveToken : Token -> List Token -> Maybe EmphasisMatchToken
retrieveToken token tokens =
    case tokens of
        [] ->
            Nothing

        tokensHead :: tokensTail ->
            if tokensHead.meaning == token.meaning then
                let
                    remainLenght : Int
                    remainLenght =
                        tokensHead.length - token.length


                    isMultipleOf3 : Bool
                    isMultipleOf3 =
                        (tokensHead.length + token.length) % 3 == 0


                    toReturn : ( Token, Token, List Token ) -> EmphasisMatchToken
                    toReturn ( openToken, closeToken, tokens ) =
                        { openToken = openToken
                        , closeToken = closeToken
                        , tokens = tokens
                        , isMultipleOf3 = isMultipleOf3 
                        }


                in
                    -- Perfect match
                    if remainLenght == 0 then
                        ( tokensHead, token, tokensTail )
                            |> toReturn
                            |> Just

                    -- Still has opened token
                    else if remainLenght > 0 then
                        ( { tokensHead
                            | index = tokensHead.index + remainLenght
                            , length = tokensHead.length - remainLenght
                          }
                        , token
                        , { tokensHead | length = remainLenght }
                            :: tokensTail
                        )   |> toReturn
                            |> Just

                    -- Still has closing token
                    -- search for more openings in addMatch
                    else
                        ( tokensHead
                        , { token | length = token.length + remainLenght }
                        , tokensTail
                        )   |> toReturn
                            |> Just

            else
                retrieveToken token tokensTail


tokenToMatch : String -> Token -> Token -> Match
tokenToMatch rawText openToken closeToken =
    let
        start = openToken.index
        end = closeToken.index + closeToken.length
        textStart = openToken.index + openToken.length
        textEnd = closeToken.index

    in
        { type_   = Emphasis openToken.length
        , start   = start
        , end     = end
        , rawText = String.slice start end rawText -- É necessário??
        , text = String.slice textStart textEnd rawText
        , matches = []
        } |> Match


updateLexerModel : LexerModel -> Match -> LexerModel
updateLexerModel model (Match match) =
    { model
        | remainText =
            String.dropLeft (match.end - match.start) model.remainText
        , index = match.end
        , matches = Match match :: model.matches
        , lastChar =
            model.rawText
                |> String.reverse
                |> String.uncons
                |> Maybe.map Tuple.first
    }



-- Inline


parse : References -> String -> List Match
parse refs rawText =
    let
        trimmedText = String.trim rawText

    in
        findMatches refs trimmedText
            |> organizeMatches
            |> parseNormalMatches trimmedText []



----- Html


toHtml : List Match -> List (Html Never)
toHtml =
    List.map matchToHtml
        >> List.concat


matchToHtml : Match -> List (Html Never)
matchToHtml (Match match) =
    case match.type_ of
        Normal ->
            [ text match.text ]


        HardBreak ->
            [ br [] [] ]


        Code ->
            [ code [] [ text match.text ] ]


        Emphasis length ->
            case length of
                1 -> [ em [] (toHtml match.matches) ]
                2 -> [ strong [] (toHtml match.matches) ]
                _ ->
                    [ strong []
                        <| matchToHtml
                        <| Match
                            { match |
                                type_ = Emphasis (length - 2)
                            }
                    ]


        Link ( url, maybeTitle ) ->
            case maybeTitle of
                Just title_ ->
                    [ a [ href url, title title_ ]
                        (toHtml match.matches)
                    ]

                Nothing ->
                    [ a [ href url ]
                        (toHtml match.matches)
                    ]


        Image ( url, maybeTitle ) ->
            case maybeTitle of
                Just title_ ->
                    [ img
                        [ alt match.text
                        , src url
                        , title title_
                        ] []
                    ]

                Nothing ->
                    [ img
                        [ alt match.text
                        , src url
                        ] []
                    ]
