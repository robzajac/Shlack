{-# LANGUAGE
  TypeFamilies, FlexibleContexts
#-}
{-# OPTIONS -fwarn-tabs -fwarn-incomplete-patterns #-}

module Client where

import Network
import Control.Concurrent
import Data.List.Split
import System.IO
import System.Console.ANSI

import Model

-- Parses user input into a Message.
parseInput :: String -> Maybe Message
parseInput str =
    case str of
        "" -> Nothing
        "logout" ->  Just $ Logout
        _ ->
            let msg = str in
            let parts = splitOn " " msg in
            case parts of
                -- Special case for whisper because it can have n tokens
                "/whisper" : p2 : rest -> Just $ Cmd $ Whisper p2 (unwords rest)
                p : [] -> case p of
                    -- Single token commands
                    '/' : cmd -> case cmd of
                        "listchannels" -> Just $ Cmd $ ListChannels
                        "listusers" -> Just $ Cmd $ ListUsers
                        "help" -> Just $ Cmd $ Help
                        _ -> Nothing
                    text -> Just $ TextData text
                p : ps ->
                    case p of
                        -- commands with 2 tokens
                        '/' : cmd -> case cmd of
                            "join" -> Just $ Cmd $ JoinChannel (concat ps)
                            _ -> Nothing
                        _ -> Just $ TextData msg
                _ -> Just $ TextData str

-- Serializes messages into a friendly intermediate format to send to server.
serializeMessage :: Message -> String
serializeMessage msg = case msg of
    TextData str -> "Message" ++ delim ++ str
    Login user -> "Login" ++ delim ++ user
    Logout -> "Logout"
    Cmd cmd -> serializeCommand cmd

-- Serializes commands into a friendly intermediate format to send to server.
serializeCommand :: Command -> String
serializeCommand cmd = case cmd of 
    JoinChannel channel -> "Join" ++ delim ++ channel
    Whisper user msg -> "Whisper" ++ delim ++ user ++ delim ++ msg
    ListChannels -> "ListChannels"
    ListUsers -> "ListUsers"
    Help -> "Help"

-- | IP address of the local host
local :: HostName
local = "127.0.0.1"

-- | Start the client given an IP address and a port. The port should
-- be a string number > 1024
client :: HostName -> PortID -> IO Handle
client = connectTo

-- Updates local state based on input
actOnMessage msg sock user chnl = 
    case msg of
        Cmd (JoinChannel c) -> do
            chnlName <- takeMVar chnl
            putMVar chnl c
            writeDivider (Just c)
            clientLoop sock user chnl
        Logout -> do
            return ()
        _ -> do
            chnlName <- takeMVar chnl
            putMVar chnl chnlName
            writeDivider (Just chnlName)
            clientLoop sock user chnl


-- Main loop of client, reads from stdin
-- parses input, updates local state and 
-- sends to server
clientLoop :: Handle -> String -> MVar String -> IO ()
clientLoop sock user chnl = do
    input <- getLine
    if input == "" then do
        scrollPageDown 1
        hFlush stdout
        clientLoop sock user chnl else
        do
            cursorUp 2
            hFlush stdout
            clearFromCursorToLineEnd
            hFlush stdout
            setSGR [SetColor Foreground Dull Cyan]
            putStr (user ++ ": " ++ input)
            hFlush stdout
            setSGR [SetColor Foreground Dull White]
            cursorDown 1
            hFlush stdout
            setCursorColumn 0
            hFlush stdout

            let maybeMsg = parseInput input
            case maybeMsg of
                Just msg ->
                    let serialMsg = serializeMessage msg in
                    do
                        hPutStr sock serialMsg
                        hFlush sock
                        actOnMessage msg sock user chnl
                Nothing -> do
                    chnlName <- takeMVar chnl
                    putMVar chnl chnlName
                    writeDivider (Just chnlName)
                    clientLoop sock user chnl

-- Quality of life function for parsing IP
parseIP :: String -> String
parseIP ip = case ip of
    -- "" -> "192.168.1.190"
    -- "" -> "192.168.1.83" 
    "" -> "128.91.165.228"
    s -> s

-- Prints the divider between messages and input
writeDivider :: Maybe String -> IO ()
writeDivider channel = 
    do
    setSGR [SetConsoleIntensity BoldIntensity]
    hFlush stdout
    setSGR [SetColor Foreground Dull Yellow]
    case channel of
        Nothing ->
            putStrLn "-----------------------------------"
        Just chnl ->
            let len = dividerLength - 2 - (length chnl) in
            putStrLn ("[" ++  chnl ++ "]" ++ (replicate len '-') )
    hFlush stdout
    setSGR [SetColor Foreground Dull White]
    setSGR [SetConsoleIntensity NormalIntensity]
    hFlush stdout

-- Data type representing a reply from the server
data Reply = RPublic String
             | RWhisper String
             | RServer String

-- Parses a reply from the server into a Reply
parseServerReply :: String -> Reply
parseServerReply msg = 
    let splits@(mode : str : xs) = splitOn delim msg in
    if (length splits == 2) then
        case mode of
            "W" -> RWhisper str
            "P" -> RPublic str
            "S" -> RServer str
            _   -> RPublic str
    else RPublic msg

-- Correctly formats a reply from the server
writeReply :: Reply -> IO ()
writeReply reply = case reply of
    RPublic str -> do
        setSGR [SetColor Foreground Dull Blue]
        putStrLn str
        setSGR [SetColor Foreground Dull White]
    RWhisper str -> do
        setSGR [SetColor Foreground Dull Magenta]
        putStrLn str
        setSGR [SetColor Foreground Dull White]
    RServer str -> do
        setSGR [SetColor Foreground Dull Green]
        putStrLn str
        setSGR [SetColor Foreground Dull White]

-- Loop that runs on a seperate thread
-- to read messages sent from the server
readLoop :: Handle -> MVar String -> IO ()
readLoop sock chnl = do
    isDone <- hIsEOF sock
    if isDone then return () else do
        line <- hGetLine sock
        cursorUp 1
        hFlush stdout
        setCursorColumn 0
        hFlush stdout
        clearFromCursorToLineEnd
        hFlush stdout
        writeReply (parseServerReply line)
        hFlush stdout
        chnlName <- takeMVar chnl
        putMVar chnl chnlName
        writeDivider (Just chnlName)
        readLoop sock chnl

-- Prints a message written as the server
printServerNotification :: String -> IO ()
printServerNotification str = do
    setSGR [SetColor Foreground Dull Green]
    hFlush stdout
    putStrLn ("[Server]: " ++ str)
    setSGR [SetColor Foreground Dull White]
    hFlush stdout

-- Prints a prompt for user input
printPrompt :: String -> IO ()
printPrompt str = do
    setSGR [SetColor Foreground Dull Yellow]
    putStrLn str
    setSGR [SetColor Foreground Dull White]
    hFlush stdout

-- Prints the welcome sequence
printWelcomeMessage :: String -> IO ()
printWelcomeMessage user = do
    printServerNotification ("hey " ++ user ++ " welcome to Shlλck!")
    putStrLn "          ,▄▄,                 ▄▄        ▄▄  ▄▄▄               ▄▄"
    putStrLn "    ,▄█▓▓▓▓▓▓▓▓▓▄              ▓▓        ▓▓    ▓▓              ▓▓ "
    putStrLn "   ▓▌,  ▀▓▓▓▓▓▓▓▓▌     ▄▄▓▓▄▄  ▓▓▄▄▓▓▄   ▓▓    ▐▓▓     ,▄▓▓▓▄▄ ▓▓   ▄▓▄"
    putStrLn "  |▓▓▓▓▓   ▓▓▓▓▓▓▓▄   ▐▓▓   ▀  ▓▓▀   ▓▓  ▓▓    ▓▓▓▌   ▓▓▓▀  ▀  ▓▓▄▄▓▓▀"
    putStrLn "  ▐▓▓▓▓▓▌ ▄  ▀▓▓▓▓▓    ▀█▓▓▓▄  ▓▓    ▓▓  ▓▓   ▓▓▀▀▓▄  ▓▓       ▓▓▓▓▓▌"
    putStrLn "   ▓▓▓▓▓▌ |▓▄   ▓▓▓    ▄  ▓▓▓  ▓▓    ▓▓  ▓▓  ▓▓▌  ▓▓▄ ▀▓▓▄__▄, ▓▓▌ ▀▓▓▄"
    putStrLn "    ▓▓▓▓▌ ▐▓▓▓▓▓▓▓`    ▀▀▀▀▀▀  ▀▀    ▀▀  ▀▀  ▀▀    ▀▀▀ '▀▀▀▀▀  ▀▀    ▀▀`"
    putStrLn "     ▀▓▓▓▓▓▓▓▓▀▀ "
    putStrLn ""
    writeDivider Nothing
    
-- Main entry point for client.
clientMain :: IO ()
clientMain = do
    printPrompt "Enter server IP"
    ip <- getLine
    printServerNotification ("connecting to: " ++ (parseIP ip))
    hFlush stdout
    sock <- client (parseIP ip) (PortNumber 4040)
    hSetBuffering sock LineBuffering
    printPrompt "Enter username"
    username <- getLine
    printWelcomeMessage username
    hPutStr sock (serializeMessage (Login username))
    hFlush sock
    chnlState <- newMVar defaultChannel
    _ <- forkIO (readLoop sock chnlState)
    writeDivider (Just defaultChannel)
    clientLoop sock username chnlState