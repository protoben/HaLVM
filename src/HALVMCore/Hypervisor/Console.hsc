-- Copyright 2013 Galois, Inc.
-- This software is distributed under a standard, three-clause BSD license.
-- Please see the file LICENSE, distributed with this software, for specific
-- terms and conditions.
module Hypervisor.Console(
         Console
       , initXenConsole
       , initConsole
       , readConsole
       , writeConsole
       )
 where

import Control.Concurrent
import Control.Concurrent.BoundedChan
import Control.Exception
import Control.Monad
import Data.Word
import Foreign.C.String
import Foreign.Ptr
import Foreign.Storable
import Hypervisor.DomainInfo
import Hypervisor.ErrorCodes
import Hypervisor.Memory
import Hypervisor.Port
import System.IO(setXenPutStr, setXenGetChar)

data ConsoleMsg = WriteString String (MVar ())
                | ReadString Int (MVar String)
                | Advance

newtype Console = Console (BoundedChan ConsoleMsg)

-- |Initialize the Xen console associated with this domain at boot time.
-- This has the side effect of rewiring putStr, getChar, and friends to
-- use the Xen console.
initXenConsole :: IO Console
initXenConsole  = do
  conMFN  <- (toMFN . fromIntegral) `fmap` get_console_mfn
  conPort <- toPort `fmap` get_console_evtchn
  con <- initConsole conMFN conPort
  setXenPutStr (writeConsole con)
  setXenGetChar (head `fmap` readConsole con 1)
  return con

-- |Initialize a console built from the given machine frame and event
-- channel.
initConsole :: MFN -> Port -> IO Console
initConsole conMFN conPort  = do
  commChan <- newChan 1024
  conPtr   <- handle (mapMFN conMFN) (mfnToVPtr conMFN)
  startConsoleThread commChan conPtr conPort
  setPortHandler conPort $ writeChan commChan Advance
  return (Console commChan)
 where
  mapMFN :: MFN -> ErrorCode -> IO (VPtr a)
  mapMFN mfn _ = mapFrames [mfn]

-- |Read data from the console, blocking until the given number of bytes
-- are available.
readConsole :: Console -> Int -> IO String
readConsole (Console commChan) amt = do
  resMV <- newEmptyMVar
  tryWriteChan commChan (ReadString amt resMV)
  postProcessOutput `fmap` takeMVar resMV

-- |Write data to the console, blocking until the string has been written to
-- the console driver. Note that writing to the console driver does not
-- necessarily mean that the string has been flushed to whatever viewing
-- device is attached to the console.
writeConsole :: Console -> String -> IO ()
writeConsole (Console commChan) str = do
  resMV <- newEmptyMVar
  tryWriteChan commChan (WriteString (preProcessInput str) resMV)
  takeMVar resMV

-- ----------------------------------------------------------------------------

-- Not sure if this is a good idea, but we convert \n to \r\n on the way out
-- of the system, and \r\n back to \n on the way back in.
preProcessInput :: String -> String
preProcessInput []          = []
preProcessInput ('\n':rest) = "\r\n" ++ preProcessInput rest
preProcessInput (   f:rest) = f : preProcessInput rest

postProcessOutput :: String -> String
postProcessOutput []               = []
postProcessOutput ('\r':'\n':rest) = '\n' : postProcessOutput rest
postProcessOutput (        f:rest) = f    : postProcessOutput rest

-- ----------------------------------------------------------------------------

data WriteToDo = WriteToDo String (MVar ())
data ReadToDo  = ReadToDo Int String (MVar String)

startConsoleThread :: Chan ConsoleMsg -> Ptr a -> Port -> IO ()
startConsoleThread commChan ring port =
  forkIO (runThread [] [] "") >> return ()
 where
  runThread rtodos wtodos rbuffer = do
    msg                        <- readChan commChan
    let (rtodos', wtodos')      = addNewToDos rtodos wtodos msg
    (newreads, shouldSignalR)  <- pullNewReads ring
    let rbuffer'                = rbuffer ++ newreads
    (rtodos'', rbuffer'')      <- solveReadToDos rtodos' rbuffer'
    (wtodos'', shouldSignalW)  <- solveWriteToDos wtodos' ring
    when (shouldSignalR || shouldSignalW) $ sendOnPort port
    runThread rtodos'' wtodos'' rbuffer''

-- If there's any new data on the ring, yank it in, and return the new data
-- and a boolean saying if we pulled anything.
pullNewReads :: Ptr a -> IO (String, Bool)
pullNewReads ring = do
  cons <- inConsumed ring
  prod <- inProduced ring
  -- FIXME: Wrap around?
  if cons /= prod
    then do bytes <- replicateM (fromIntegral (prod - cons)) readByte
            return (bytes, True)
    else return ("", False)
 where
  -- simplicity over complex efficiency. this is a console, after all.
  readByte :: IO Char
  readByte = do
    cons <- inConsumed ring
    resb <- peekByteOff (inBuffer ring) (fromIntegral (cons `mod` inBufferSize))
    setInConsumed ring (cons + 1)
    return (castCUCharToChar resb)

solveReadToDos :: [ReadToDo] -> String -> IO ([ReadToDo], String)
solveReadToDos [] s  = return ([], s)
solveReadToDos ts "" = return (ts, "")
solveReadToDos ((ReadToDo n acc resmv) : rest) str = do
  let (curstr, reststr) = splitAt n str
      n'                = n - (length curstr)
  assert (n' >= 0) $ return ()
  if n' == 0
    then do putMVar resmv (acc ++ curstr)
            solveReadToDos rest reststr
    else do assert (reststr == "") $ return ()
            return (((ReadToDo n' (acc ++ curstr) resmv) : rest), "")

solveWriteToDos :: [WriteToDo] -> Ptr a -> IO ([WriteToDo], Bool)
solveWriteToDos [] _ = return ([], False)
solveWriteToDos ((WriteToDo "" resmv) : rest) ring = do
  putMVar resmv ()
  solveWriteToDos rest ring
solveWriteToDos orig@((WriteToDo (f:rstr) resmv) : rest) ring = do
  cons <- outConsumed ring
  prod <- outProduced ring
  if (prod - cons) < outBufferSize
    then do writeChar f
            let todos      = (WriteToDo rstr resmv) : rest
            (rettodos, _) <- solveWriteToDos todos ring
            return (rettodos, True)
    else return (orig, False)
 where
  writeChar :: Char -> IO ()
  writeChar v = do
    prod <- outProduced ring
    pokeByteOff (outBuffer ring) (fromIntegral prod `mod` outBufferSize) v
    setOutProduced ring (prod + 1)

-- Given a message, add it to our lists of things to do.
addNewToDos :: [ReadToDo] -> [WriteToDo] -> ConsoleMsg ->
               ([ReadToDo], [WriteToDo])
addNewToDos rtodos wtodos Advance           = (rtodos, wtodos)
addNewToDos rtodos wtodos (WriteString s m) = (rtodos, wtodos++[WriteToDo s m])
addNewToDos rtodos wtodos (ReadString  n m) = (rtodos++[ReadToDo n "" m],wtodos)

-- ----------------------------------------------------------------------------

#include <stdint.h>
#include <sys/types.h>
#include <xen/io/console.h>

inBufferSize :: Integral a => a
inBufferSize  = 1024

outBufferSize :: Integral a => a
outBufferSize  = 2048

inBuffer :: Ptr a -> Ptr Word8
inBuffer p = (#ptr struct xencons_interface,in) p

outBuffer :: Ptr a -> Ptr Word8
outBuffer p = (#ptr struct xencons_interface,out) p

inConsumed :: Ptr a -> IO Word32
inConsumed p = (#peek struct xencons_interface,in_cons) p

setInConsumed :: Ptr a -> Word32 -> IO ()
setInConsumed p v = (#poke struct xencons_interface,in_cons) p v

inProduced :: Ptr a -> IO Word32
inProduced p = (#peek struct xencons_interface,in_prod) p

outConsumed :: Ptr a -> IO Word32
outConsumed p = (#peek struct xencons_interface,out_cons) p

outProduced :: Ptr a -> IO Word32
outProduced p = (#peek struct xencons_interface,out_prod) p

setOutProduced :: Ptr a -> Word32 -> IO ()
setOutProduced p v = (#poke struct xencons_interface,out_prod) p v

foreign import ccall unsafe "domain_info.h get_console_evtchn"
  get_console_evtchn :: IO Word32

foreign import ccall unsafe "domain_info.h get_console_mfn"
  get_console_mfn :: IO Word

