import React, { useState, useRef, useCallback } from 'react';
import { Mic } from 'lucide-react';

const SpeechRecognition = typeof window !== 'undefined'
  ? (window.SpeechRecognition || window.webkitSpeechRecognition)
  : null;

function sendInput(ws, data) {
  if (ws.current && ws.current.readyState === WebSocket.OPEN) {
    ws.current.send(JSON.stringify({ type: 'input', data }));
  }
}

function KeyButton({ label, onClick, className = '' }) {
  return (
    <button
      type="button"
      onMouseDown={(e) => e.preventDefault()}
      onClick={onClick}
      className={`flex-shrink-0 min-w-[2.5rem] h-9 px-2 rounded text-sm font-medium text-gray-200 bg-gray-700 hover:bg-gray-600 active:bg-gray-500 touch-manipulation select-none ${className}`}
    >
      {label}
    </button>
  );
}

function MicButton({ lang, label, ws }) {
  const [active, setActive] = useState(false);
  const recognitionRef = useRef(null);

  const toggle = useCallback(() => {
    if (active && recognitionRef.current) {
      recognitionRef.current.stop();
      recognitionRef.current = null;
      setActive(false);
      return;
    }

    const recognition = new SpeechRecognition();
    recognition.lang = lang;
    recognition.interimResults = false;
    recognition.continuous = false;

    recognition.onresult = (event) => {
      const transcript = event.results[0]?.[0]?.transcript;
      if (transcript) {
        sendInput(ws, transcript);
      }
    };

    recognition.onend = () => {
      recognitionRef.current = null;
      setActive(false);
    };

    recognition.onerror = () => {
      recognitionRef.current = null;
      setActive(false);
    };

    recognitionRef.current = recognition;
    setActive(true);
    recognition.start();
  }, [active, lang, ws]);

  return (
    <button
      type="button"
      onMouseDown={(e) => e.preventDefault()}
      onClick={toggle}
      className={`flex-shrink-0 min-w-[2.5rem] h-9 px-2 rounded text-sm font-medium touch-manipulation select-none flex items-center justify-center gap-1 ${
        active
          ? 'animate-pulse bg-red-600 text-white'
          : 'bg-gray-700 text-gray-200 hover:bg-gray-600 active:bg-gray-500'
      }`}
    >
      <Mic size={14} />
      <span className="text-xs">{label}</span>
    </button>
  );
}

export default function TerminalButtonBar({ ws, isConnected }) {
  if (!isConnected) return null;

  const hasSpeech = !!SpeechRecognition;

  return (
    <div className="flex-shrink-0 bg-gray-800 border-t border-gray-700 px-2 py-1.5 flex flex-wrap gap-1.5 max-h-[5rem]">
      {hasSpeech && (
        <>
          <MicButton lang="zh-TW" label="TW" ws={ws} />
          <MicButton lang="en-US" label="EN" ws={ws} />
        </>
      )}
      <KeyButton label="Tab" onClick={() => sendInput(ws, '\t')} />
      <KeyButton label="⇧Tab" onClick={() => sendInput(ws, '\x1b[Z')} />
      <KeyButton label="Esc" onClick={() => sendInput(ws, '\x1b')} />
      <KeyButton label="^C" onClick={() => sendInput(ws, '\x03')} />
      <KeyButton label="^Z" onClick={() => sendInput(ws, '\x1a')} />
      <KeyButton label="↑" onClick={() => sendInput(ws, '\x1b[A')} />
      <KeyButton label="↓" onClick={() => sendInput(ws, '\x1b[B')} />
      <KeyButton label="←" onClick={() => sendInput(ws, '\x1b[D')} />
      <KeyButton label="→" onClick={() => sendInput(ws, '\x1b[C')} />
      <KeyButton label="⌫" onClick={() => sendInput(ws, '\x7f')} />
      <KeyButton label="␣" onClick={() => sendInput(ws, ' ')} />
      <KeyButton label="↵" onClick={() => sendInput(ws, '\r')} className="bg-green-700 hover:bg-green-600 active:bg-green-500" />
    </div>
  );
}
