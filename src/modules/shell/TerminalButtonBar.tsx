import { type MutableRefObject, useCallback, useRef, useState } from 'react';
import { Mic } from 'lucide-react';

import { sendSocketMessage } from '@/modules/shell/utils/socket';

type SpeechRecognitionAlternativeLike = {
  transcript?: string;
};

type SpeechRecognitionResultEventLike = {
  results: ArrayLike<ArrayLike<SpeechRecognitionAlternativeLike>>;
};

type SpeechRecognitionInstance = {
  lang: string;
  interimResults: boolean;
  continuous: boolean;
  onresult: ((event: SpeechRecognitionResultEventLike) => void) | null;
  onend: (() => void) | null;
  onerror: (() => void) | null;
  start: () => void;
  stop: () => void;
};

type SpeechRecognitionConstructor = new () => SpeechRecognitionInstance;

type WindowWithSpeechRecognition = Window & {
  SpeechRecognition?: SpeechRecognitionConstructor;
  webkitSpeechRecognition?: SpeechRecognitionConstructor;
};

function getSpeechRecognitionConstructor(): SpeechRecognitionConstructor | null {
  if (typeof window === 'undefined') {
    return null;
  }
  const speechWindow = window as WindowWithSpeechRecognition;
  return speechWindow.SpeechRecognition || speechWindow.webkitSpeechRecognition || null;
}

function sendInput(ws: MutableRefObject<WebSocket | null>, data: string) {
  sendSocketMessage(ws.current, { type: 'input', data });
}

type KeyButtonProps = {
  label: string;
  onClick: () => void;
  className?: string;
};

function KeyButton({ label, onClick, className = '' }: KeyButtonProps) {
  return (
    <button
      type="button"
      onMouseDown={(e) => e.preventDefault()}
      onClick={onClick}
      className={`h-9 min-w-10 flex-shrink-0 touch-manipulation select-none rounded bg-gray-700 px-2 text-sm font-medium text-gray-200 hover:bg-gray-600 active:bg-gray-500 ${className}`}
    >
      {label}
    </button>
  );
}

type MicButtonProps = {
  lang: string;
  label: string;
  ws: MutableRefObject<WebSocket | null>;
};

function MicButton({ lang, label, ws }: MicButtonProps) {
  // Tracks whether browser speech recognition is currently listening for voice input.
  const [active, setActive] = useState(false);
  const recognitionRef = useRef<SpeechRecognitionInstance | null>(null);

  const toggle = useCallback(() => {
    if (active && recognitionRef.current) {
      recognitionRef.current.stop();
      recognitionRef.current = null;
      setActive(false);
      return;
    }

    const SpeechRecognitionCtor = getSpeechRecognitionConstructor();
    if (!SpeechRecognitionCtor) {
      return;
    }

    const recognition = new SpeechRecognitionCtor();
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
      className={`flex h-9 min-w-10 flex-shrink-0 touch-manipulation select-none items-center justify-center gap-1 rounded px-2 text-sm font-medium ${
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

type TerminalButtonBarProps = {
  ws: MutableRefObject<WebSocket | null>;
  isConnected: boolean;
};

/** Rendered by Shell at the bottom of the terminal view to provide voice input and quick terminal key buttons on desktop and mobile. */
export default function TerminalButtonBar({ ws, isConnected }: TerminalButtonBarProps) {
  if (!isConnected) return null;

  const hasSpeech = Boolean(getSpeechRecognitionConstructor());

  return (
    <div className="flex max-h-20 flex-shrink-0 flex-wrap gap-1.5 border-t border-gray-700 bg-gray-800 px-2 py-1.5">
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
      <KeyButton
        label="↵"
        onClick={() => sendInput(ws, '\r')}
        className="bg-green-700 hover:bg-green-600 active:bg-green-500"
      />
    </div>
  );
}
