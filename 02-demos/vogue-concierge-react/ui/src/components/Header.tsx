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

import { Sparkles, MessageSquarePlus } from 'lucide-react';

export default function Header({ onNewChat }: { onNewChat?: () => void }) {
  return (
    <header className="border-b border-gray-200 bg-white/90 backdrop-blur-md sticky top-0 z-50">
      <div className="max-w-5xl mx-auto px-4 py-3 flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="w-9 h-9 rounded-lg bg-gradient-to-br from-gold-400 to-gold-600 flex items-center justify-center shadow-lg shadow-gold-400/20">
            <span className="font-display text-white text-lg font-bold tracking-tight">V</span>
          </div>
          <div>
            <h1 className="font-display text-lg font-medium tracking-wide text-gray-900">Vogue Concierge</h1>
            <p className="text-[10px] text-gray-400 tracking-[0.2em] uppercase -mt-0.5">AI Boutique</p>
          </div>
        </div>
        <div className="flex items-center gap-3">
          <div className="hidden lg:flex items-center gap-1.5 text-xs text-gold-500">
            <Sparkles size={12} />
            <span className="tracking-wide">Claude on Agent Platform</span>
          </div>
          {onNewChat && (
            <button onClick={onNewChat} title="New Conversation"
              className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg border border-gray-200 bg-white hover:bg-gold-50 hover:border-gold-300 text-gray-500 hover:text-gold-600 transition-all duration-300 text-xs font-medium">
              <MessageSquarePlus size={14} />
              <span className="hidden sm:inline">New Chat</span>
            </button>
          )}
          <div className="w-2 h-2 rounded-full bg-emerald-400 shadow-sm shadow-emerald-400/50" title="Agent Online"></div>
        </div>
      </div>
    </header>
  );
}
