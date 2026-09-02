'use client';
// Copyright 2026 The "Anthropic on Google Cloud" Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import { useState, useRef, useEffect } from 'react';
import Header from '../components/Header';
import ChatMessage from '../components/ChatMessage';
import ProductCards from '../components/ProductCards';
import SamplePrompts from '../components/SamplePrompts';
import { Send, Loader2 } from 'lucide-react';

interface Message { role: 'user' | 'assistant'; content: string; products?: Product[]; }
interface Product { sku: string; name: string; price: number; category: string; description: string; color?: string; material?: string; image_url?: string; occasions?: string[]; }

export default function Home() {
  const [messages, setMessages] = useState<Message[]>([]);
  const [input, setInput] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [streaming, setStreaming] = useState(false);
  const [sessionId, setSessionId] = useState<string | null>(null);
  const [showWelcome, setShowWelcome] = useState(true);
  const messagesEndRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => { messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' }); }, [messages]);
  useEffect(() => { inputRef.current?.focus(); }, []);

  const handleNewChat = () => { setMessages([]); setShowWelcome(true); setInput(''); setSessionId(null); };

  const handleSubmit = async (text?: string) => {
    const messageText = text || input.trim();
    if (!messageText || isLoading) return;
    setShowWelcome(false);
    setInput('');
    const userMessage: Message = { role: 'user', content: messageText };
    setMessages(prev => [...prev, userMessage]);
    setIsLoading(true);
    const history = [...messages, userMessage].map(m => ({ role: m.role, content: m.content }));

    // Update (or create) the streaming assistant message — always the last one.
    let started = false;
    const upsertAssistant = (msg: Message) => {
      setMessages(prev => {
        if (!started) return [...prev, msg];
        const copy = [...prev];
        copy[copy.length - 1] = msg;
        return copy;
      });
    };

    try {
      const response = await fetch('/api/chat/stream', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ messages: history, session_id: sessionId }),
      });
      if (!response.ok || !response.body) throw new Error(`HTTP ${response.status}`);
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const frames = buffer.split('\n\n');
        buffer = frames.pop() || '';
        for (const frame of frames) {
          const line = frame.trim();
          if (!line.startsWith('data:')) continue;
          const obj = JSON.parse(line.slice(5).trim());
          if (obj.delta) {
            setStreaming(true);
            upsertAssistant({ role: 'assistant', content: obj.delta });
            started = true;
          } else if (obj.final) {
            if (obj.final.session_id) setSessionId(obj.final.session_id);
            upsertAssistant({ role: 'assistant', content: obj.final.response, products: obj.final.products || [] });
            started = true;
          }
        }
      }
    } catch (error) {
      // Fallback to the non-streaming endpoint so a stream hiccup never blocks chat.
      try {
        const r = await fetch('/api/chat', {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ messages: history, session_id: sessionId }),
        });
        const data = await r.json();
        if (data.session_id) setSessionId(data.session_id);
        upsertAssistant({ role: 'assistant', content: data.response, products: data.products || [] });
      } catch (e2) {
        upsertAssistant({ role: 'assistant', content: 'I apologize, but I encountered an issue. Please try again.\n\n[Vogue Concierge]' });
      }
    } finally {
      setIsLoading(false);
      setStreaming(false);
      inputRef.current?.focus();
    }
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); handleSubmit(); }
  };

  return (
    <div className="flex flex-col h-screen max-h-screen overflow-hidden bg-white">
      <Header onNewChat={handleNewChat} />
      <main className="flex-1 overflow-y-auto px-4 md:px-0">
        <div className="max-w-3xl mx-auto py-6">
          {showWelcome && (
            <div className="flex flex-col items-center justify-center min-h-[60vh] animate-fade-in">
              {/* ANTHROPIC x GOOGLE — text based */}
              <div className="flex flex-col items-center mb-8">
                <div className="flex items-center gap-3 mb-1">
                  <span className="text-2xl font-bold tracking-tight text-[#CC785C]">Anthropic</span>
                  <span className="text-lg text-gray-300 font-light">&times;</span>
                  <span className="text-2xl font-bold tracking-tight">
                    <span className="text-blue-500">G</span><span className="text-red-500">o</span><span className="text-yellow-500">o</span><span className="text-blue-500">g</span><span className="text-green-500">l</span><span className="text-red-500">e</span>
                  </span>
                </div>
                <span className="text-xs text-gray-400 tracking-[0.3em] uppercase">Better Together</span>
              </div>

              <div className="text-center mb-10">
                <h2 className="font-display text-3xl md:text-4xl font-medium text-gray-900 mb-3 tracking-wide">Welcome to Your Boutique</h2>
                <p className="text-gray-500 text-base max-w-md mx-auto leading-relaxed">Your personal stylist, inventory specialist, and fashion advisor — all in one conversation.</p>
              </div>
              <SamplePrompts onSelect={handleSubmit} />
              <div className="mt-10 flex flex-wrap items-center justify-center gap-4 text-xs text-gray-400">
                <div className="flex items-center gap-2"><div className="w-1.5 h-1.5 rounded-full bg-[#CC785C]"></div><span>Claude on Agent Platform</span></div>
                <div className="flex items-center gap-2"><div className="w-1.5 h-1.5 rounded-full bg-green-500"></div><span>Google ADK</span></div>
                <div className="flex items-center gap-2"><div className="w-1.5 h-1.5 rounded-full bg-yellow-500"></div><span>MCP Toolbox</span></div>
                <div className="flex items-center gap-2"><div className="w-1.5 h-1.5 rounded-full bg-gold-500"></div><span>Agent Platform RAG Engine</span></div>
              </div>
            </div>
          )}
          {messages.map((message, index) => (
            <div key={index} className="animate-slide-up" style={{ animationDelay: `${index * 0.05}s` }}>
              <ChatMessage message={message} />
              {message.products && message.products.length > 0 && <ProductCards products={message.products} />}
            </div>
          ))}
          {isLoading && !streaming && (
            <div className="flex items-start gap-3 py-4 animate-fade-in">
              <div className="w-8 h-8 rounded-full bg-gold-50 border border-gold-200 flex items-center justify-center flex-shrink-0">
                <span className="text-gold-600 text-xs font-display font-semibold">V</span>
              </div>
              <div className="flex items-center gap-2 mt-2">
                <div className="flex gap-1">
                  <div className="w-1.5 h-1.5 rounded-full bg-gold-400 animate-bounce" style={{ animationDelay: '0ms' }}></div>
                  <div className="w-1.5 h-1.5 rounded-full bg-gold-400 animate-bounce" style={{ animationDelay: '150ms' }}></div>
                  <div className="w-1.5 h-1.5 rounded-full bg-gold-400 animate-bounce" style={{ animationDelay: '300ms' }}></div>
                </div>
                <span className="text-gray-400 text-sm ml-2">Curating your response...</span>
              </div>
            </div>
          )}
          <div ref={messagesEndRef} />
        </div>
      </main>
      <div className="border-t border-gray-200 bg-white/80 backdrop-blur-sm">
        <div className="max-w-3xl mx-auto px-4 py-4">
          {!showWelcome && messages.length > 0 && (
            <div className="flex gap-2 mb-3 overflow-x-auto pb-1">
              {['Show me leather accessories', 'What\u2019s trending?', 'Check my loyalty status'].map((prompt) => (
                <button key={prompt} onClick={() => handleSubmit(prompt)}
                  className="flex-shrink-0 text-xs px-3 py-1.5 rounded-full border border-gray-200 text-gray-500 hover:border-gold-400 hover:text-gold-600 transition-all duration-300">{prompt}</button>
              ))}
            </div>
          )}
          <div className="flex items-end gap-3">
            <div className="flex-1">
              <textarea ref={inputRef} value={input} onChange={(e) => setInput(e.target.value)} onKeyDown={handleKeyDown}
                placeholder="Ask your personal stylist..." rows={1}
                className="w-full bg-gray-50 border border-gray-200 rounded-xl px-4 py-3 text-sm text-gray-900 placeholder-gray-400 focus:outline-none focus:border-gold-400 focus:ring-1 focus:ring-gold-400/20 resize-none transition-all duration-300 font-body"
                style={{ minHeight: '48px', maxHeight: '120px' }}
                onInput={(e) => { const t = e.target as HTMLTextAreaElement; t.style.height = 'auto'; t.style.height = Math.min(t.scrollHeight, 120) + 'px'; }}
              />
            </div>
            <button onClick={() => handleSubmit()} disabled={!input.trim() || isLoading}
              className="w-12 h-12 flex items-center justify-center rounded-xl bg-gold-400 text-white hover:bg-gold-500 disabled:bg-gray-200 disabled:text-gray-400 transition-all duration-300 flex-shrink-0">
              {isLoading ? <Loader2 size={18} className="animate-spin" /> : <Send size={18} />}
            </button>
          </div>
          <p className="text-center text-[10px] text-gray-400 mt-3">Anthropic &times; Google Better Together &bull; Claude on Agent Platform &bull; Google ADK &bull; MCP Toolbox &bull; Agent Platform RAG Engine</p>
        </div>
      </div>
    </div>
  );
}
