-- Copyright (c) 2013, Kenton Varda <temporal@gmail.com>
-- All rights reserved.
--
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions are met:
--
-- 1. Redistributions of source code must retain the above copyright notice, this
--    list of conditions and the following disclaimer.
-- 2. Redistributions in binary form must reproduce the above copyright notice,
--    this list of conditions and the following disclaimer in the documentation
--    and/or other materials provided with the distribution.
--
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
-- ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
-- WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
-- DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
-- ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
-- (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
-- LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
-- ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
-- (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
-- SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

module Parser (parseFile) where

import Text.Parsec hiding (tokens)
import Text.Parsec.Error(newErrorMessage, Message(Message))
import Text.Printf(printf)
import Token
import Grammar
import Semantics(maxFieldNumber, maxMethodNumber)
import Lexer (lexer)
import Control.Monad.Identity

tokenParser :: (Located Token -> Maybe a) -> Parsec [Located Token] u a
tokenParser = token (tokenErrorString . locatedValue) locatedPos

tokenErrorString (Identifier s) = "identifier \"" ++ s ++ "\""
tokenErrorString (ParenthesizedList _) = "parenthesized list"
tokenErrorString (BracketedList _) = "bracketed list"
tokenErrorString (LiteralInt i) = "integer literal " ++ show i
tokenErrorString (LiteralFloat f) = "float literal " ++ show f
tokenErrorString (LiteralString s) = "string literal " ++  show s
tokenErrorString AtSign = "\"@\""
tokenErrorString Colon = "\":\""
tokenErrorString Period = "\".\""
tokenErrorString EqualsSign = "\"=\""
tokenErrorString MinusSign = "\"-\""
tokenErrorString ExclamationPoint = "\"!\""
tokenErrorString InKeyword = "keyword \"in\""
tokenErrorString OfKeyword = "keyword \"of\""
tokenErrorString OnKeyword = "keyword \"on\""
tokenErrorString AsKeyword = "keyword \"as\""
tokenErrorString WithKeyword = "keyword \"with\""
tokenErrorString FromKeyword = "keyword \"from\""
tokenErrorString ImportKeyword = "keyword \"import\""
tokenErrorString UsingKeyword = "keyword \"using\""
tokenErrorString ConstKeyword = "keyword \"const\""
tokenErrorString EnumKeyword = "keyword \"enum\""
tokenErrorString StructKeyword = "keyword \"struct\""
tokenErrorString UnionKeyword = "keyword \"union\""
tokenErrorString InterfaceKeyword = "keyword \"interface\""
tokenErrorString OptionKeyword = "keyword \"option\""

type TokenParser = Parsec [Located Token] [ParseError]

located :: TokenParser t -> TokenParser (Located t)
located p = do
    input <- getInput
    t <- p
    return (Located (locatedPos (head input)) t)

-- Hmm, boilerplate is not supposed to happen in Haskell.
matchIdentifier t        = case locatedValue t of { (Identifier        v) -> Just v; _ -> Nothing }
matchParenthesizedList t = case locatedValue t of { (ParenthesizedList v) -> Just v; _ -> Nothing }
matchBracketedList t     = case locatedValue t of { (BracketedList     v) -> Just v; _ -> Nothing }
matchLiteralInt t        = case locatedValue t of { (LiteralInt        v) -> Just v; _ -> Nothing }
matchLiteralFloat t      = case locatedValue t of { (LiteralFloat      v) -> Just v; _ -> Nothing }
matchLiteralString t     = case locatedValue t of { (LiteralString     v) -> Just v; _ -> Nothing }
matchSimpleToken expected t = if locatedValue t == expected then Just () else Nothing

identifier = tokenParser matchIdentifier <?> "identifier"
literalInt = tokenParser matchLiteralInt <?> "integer"
literalFloat = tokenParser matchLiteralFloat <?> "floating-point number"
literalString = tokenParser matchLiteralString <?> "string"

atSign = tokenParser (matchSimpleToken AtSign) <?> "\"@\""
colon = tokenParser (matchSimpleToken Colon) <?> "\":\""
period = tokenParser (matchSimpleToken Period) <?> "\".\""
equalsSign = tokenParser (matchSimpleToken EqualsSign) <?> "\"=\""
minusSign = tokenParser (matchSimpleToken MinusSign) <?> "\"=\""
exclamationPoint = tokenParser (matchSimpleToken ExclamationPoint) <?> "\"!\""
inKeyword = tokenParser (matchSimpleToken InKeyword) <?> "\"in\""
importKeyword = tokenParser (matchSimpleToken ImportKeyword) <?> "\"import\""
usingKeyword = tokenParser (matchSimpleToken UsingKeyword) <?> "\"using\""
constKeyword = tokenParser (matchSimpleToken ConstKeyword) <?> "\"const\""
enumKeyword = tokenParser (matchSimpleToken EnumKeyword) <?> "\"enum\""
structKeyword = tokenParser (matchSimpleToken StructKeyword) <?> "\"struct\""
unionKeyword = tokenParser (matchSimpleToken UnionKeyword) <?> "\"union\""
interfaceKeyword = tokenParser (matchSimpleToken InterfaceKeyword) <?> "\"interface\""
optionKeyword = tokenParser (matchSimpleToken OptionKeyword) <?> "\"option\""

parenthesizedList parser = do
    items <- tokenParser matchParenthesizedList
    parseList parser items
bracketedList parser = do
    items <- tokenParser matchBracketedList
    parseList parser items

declNameBase :: TokenParser DeclName
declNameBase = liftM ImportName (importKeyword >> located literalString)
           <|> liftM AbsoluteName (period >> located identifier)
           <|> liftM RelativeName (located identifier)

declName :: TokenParser DeclName
declName = do
    base <- declNameBase
    members <- many (period >> located identifier)
    return (foldl MemberName base members :: DeclName)

typeExpression :: TokenParser TypeExpression
typeExpression = do
    name <- declName
    suffixes <- option [] (parenthesizedList typeExpression)
    return (TypeExpression name suffixes)

nameWithOrdinal :: Integer -> TokenParser (Located String, Located Integer)
nameWithOrdinal maxNumber = do
    name <- located identifier
    atSign
    ordinal <- located literalInt
    if locatedValue ordinal > maxNumber - 32 && locatedValue ordinal <= maxNumber
        then exclamationPoint
         <|> failNonFatal (locatedPos ordinal)
                 (printf "%d is nearing maximum of %d.  Be sure to plan for future extensibility \
                         \before you run out of numbers, e.g. by declaring a new nested type which \
                         \can hold future declarations.  To acknowledge this warning, add an \
                         \exclamation point after the number, i.e.:  %s@%d!"
                         (locatedValue ordinal) maxNumber (locatedValue name)
                         (locatedValue ordinal))
        else optional exclamationPoint
    return (name, ordinal)

topLine :: Maybe [Located Statement] -> TokenParser Declaration
topLine Nothing = optionDecl <|> aliasDecl <|> constantDecl
topLine (Just statements) = typeDecl statements

aliasDecl = do
    usingKeyword
    name <- located identifier
    equalsSign
    target <- declName
    return (AliasDecl name target)

constantDecl = do
    constKeyword
    name <- located identifier
    colon
    typeName <- typeExpression
    equalsSign
    value <- located fieldValue
    return (ConstantDecl name typeName value)

typeDecl statements = enumDecl statements
                  <|> structDecl statements
                  <|> interfaceDecl statements

enumDecl statements = do
    enumKeyword
    name <- located identifier
    children <- parseBlock enumLine statements
    return (EnumDecl name children)

enumLine :: Maybe [Located Statement] -> TokenParser Declaration
enumLine Nothing = optionDecl <|> enumValueDecl []
enumLine (Just statements) = enumValueDecl statements

enumValueDecl statements = do
    name <- located identifier
    equalsSign
    value <- located literalInt
    children <- parseBlock enumValueLine statements
    return (EnumValueDecl name value children)

enumValueLine :: Maybe [Located Statement] -> TokenParser Declaration
enumValueLine Nothing = optionDecl
enumValueLine (Just _) = fail "Blocks not allowed here."

structDecl statements = do
    structKeyword
    name <- located identifier
    children <- parseBlock structLine statements
    return (StructDecl name children)

structLine :: Maybe [Located Statement] -> TokenParser Declaration
structLine Nothing = optionDecl <|> constantDecl <|> unionDecl [] <|> fieldDecl []
structLine (Just statements) = typeDecl statements <|> unionDecl statements <|> fieldDecl statements

unionDecl statements = do
    unionKeyword
    (name, ordinal) <- nameWithOrdinal maxFieldNumber
    children <- parseBlock unionLine statements
    return (UnionDecl name ordinal children)

unionLine :: Maybe [Located Statement] -> TokenParser Declaration
unionLine Nothing = optionDecl <|> fieldDecl []
unionLine (Just statements) = fieldDecl statements

fieldDecl statements = do
    (name, ordinal) <- nameWithOrdinal maxFieldNumber
    union <- optionMaybe (inKeyword >> located identifier)
    colon
    t <- typeExpression
    value <- optionMaybe (equalsSign >> located fieldValue)
    children <- parseBlock fieldLine statements
    return (FieldDecl name ordinal union t value children)

negativeFieldValue = liftM (IntegerFieldValue . negate) literalInt
                 <|> liftM (FloatFieldValue . negate) literalFloat

fieldValue = liftM IntegerFieldValue literalInt
         <|> liftM FloatFieldValue literalFloat
         <|> liftM StringFieldValue literalString
         <|> liftM IdentifierFieldValue identifier
         <|> liftM ListFieldValue (bracketedList (located fieldValue))
         <|> liftM RecordFieldValue (parenthesizedList fieldAssignment)
         <|> (minusSign >> negativeFieldValue)
         <?> "default value"

fieldAssignment = do
    name <- located identifier
    equalsSign
    value <- located fieldValue
    return (name, value)

fieldLine :: Maybe [Located Statement] -> TokenParser Declaration
fieldLine Nothing = optionDecl
fieldLine (Just _) = fail "Blocks not allowed here."

interfaceDecl statements = do
    interfaceKeyword
    name <- located identifier
    children <- parseBlock interfaceLine statements
    return (InterfaceDecl name children)

interfaceLine :: Maybe [Located Statement] -> TokenParser Declaration
interfaceLine Nothing = optionDecl <|> constantDecl <|> methodDecl []
interfaceLine (Just statements) = typeDecl statements <|> methodDecl statements

methodDecl statements = do
    (name, ordinal) <- nameWithOrdinal maxMethodNumber
    params <- parenthesizedList paramDecl
    colon
    t <- typeExpression
    children <- parseBlock methodLine statements
    return (MethodDecl name ordinal params t children)

paramDecl = do
    name <- identifier
    colon
    t <- typeExpression
    value <- optionMaybe (equalsSign >> located fieldValue)
    return (name, t, value)

methodLine :: Maybe [Located Statement] -> TokenParser Declaration
methodLine Nothing = optionDecl
methodLine (Just _) = fail "Blocks not allowed here."

optionDecl = do
    optionKeyword
    name <- declName
    equalsSign
    value <- located fieldValue
    return (OptionDecl name value)

extractErrors :: Either ParseError (a, [ParseError]) -> [ParseError]
extractErrors (Left err) = [err]
extractErrors (Right (_, errors)) = errors

failNonFatal :: SourcePos -> String -> TokenParser ()
failNonFatal pos msg = modifyState (newError:) where
    newError = newErrorMessage (Message msg) pos

parseList parser items = finish where
    results = map (parseCollectingErrors parser) items
    finish = do
        modifyState (\old -> concat (old:map extractErrors results))
        return [ result | Right (result, _) <- results ]

parseBlock :: (Maybe [Located Statement] -> TokenParser Declaration)
           -> [Located Statement] -> TokenParser [Declaration]
parseBlock parser statements = finish where
    results = map (parseStatement parser) statements
    finish = do
        modifyState (\old -> concat (old:map extractErrors results))
        return [ result | Right (result, _) <- results ]

parseCollectingErrors :: TokenParser a -> [Located Token] -> Either ParseError (a, [ParseError])
parseCollectingErrors parser tokens = runParser parser' [] "" tokens where
    parser' = do
        -- Work around Parsec bug:  Text.Parsec.Print.token is supposed to produce a parser that
        -- sets the position by using the provided function to extract it from each token.  However,
        -- it doesn't bother to call this function for the *first* token, only subsequent tokens.
        -- The first token is always assumed to be at 1:1.  To fix this, set it manually.
        case tokens of
            Located pos _:_ -> setPosition pos
            [] -> return ()

        result <- parser
        eof
        errors <- getState
        return (result, errors)

parseStatement :: (Maybe [Located Statement] -> TokenParser Declaration)
               -> Located Statement
               -> Either ParseError (Declaration, [ParseError])
parseStatement parser (Located _ (Line tokens)) =
    parseCollectingErrors (parser Nothing) tokens
parseStatement parser (Located _ (Block tokens statements)) =
    parseCollectingErrors (parser (Just statements)) tokens

parseFileTokens :: [Located Statement] -> ([Declaration], [ParseError])
parseFileTokens statements = (decls, errors) where
    results = map (parseStatement topLine) statements
    errors = concatMap extractErrors results
    decls = [ result | Right (result, _) <- results ]

parseFile :: String -> String -> ([Declaration], [ParseError])
parseFile filename text = case parse lexer filename text of
    Left e -> ([], [e])
    Right tokens -> parseFileTokens tokens
