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

import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { User } from 'lucide-react';

interface Message { role: 'user' | 'assistant'; content: string; products?: any[]; }

export default function ChatMessage({ message }: { message: Message }) {
  const isUser = message.role === 'user';
  return (
    <div className={`flex items-start gap-3 py-4 ${isUser ? 'flex-row-reverse' : ''}`}>
      {isUser ? (
        <div className="w-8 h-8 rounded-full bg-gray-100 border border-gray-200 flex items-center justify-center flex-shrink-0">
          <User size={14} className="text-gray-500" />
        </div>
      ) : (
        <div className="w-8 h-8 rounded-full bg-gold-50 border border-gold-200 flex items-center justify-center flex-shrink-0">
          <span className="text-gold-600 text-xs font-display font-semibold">V</span>
        </div>
      )}
      <div className={`max-w-[85%] rounded-2xl px-4 py-3 ${
        isUser ? 'bg-gold-400 text-white rounded-tr-sm' : 'bg-gray-50 border border-gray-200 text-gray-800 rounded-tl-sm'
      }`}>
        {isUser ? (
          <p className="text-sm leading-relaxed font-medium">{message.content}</p>
        ) : (
          <div className="message-content text-sm leading-relaxed">
            <ReactMarkdown
              remarkPlugins={[remarkGfm]}
              components={{
                p: ({ children }) => <p className="mb-2 last:mb-0">{children}</p>,
                strong: ({ children }) => <strong className="text-gold-700 font-semibold">{children}</strong>,
                h2: ({ children }) => <h2 className="font-display text-gold-700 text-base font-semibold mt-3 mb-2">{children}</h2>,
                h3: ({ children }) => <h3 className="font-display text-gold-700 text-sm font-semibold mt-2 mb-1">{children}</h3>,
                ul: ({ children }) => <ul className="list-disc list-inside space-y-1 my-2 text-gray-700">{children}</ul>,
                ol: ({ children }) => <ol className="list-decimal list-inside space-y-1 my-2 text-gray-700">{children}</ol>,
                li: ({ children }) => <li className="text-sm">{children}</li>,
                table: ({ children }) => (
                  <div className="overflow-x-auto my-3 rounded-lg border border-gold-200">
                    <table className="w-full text-sm border-collapse">{children}</table>
                  </div>
                ),
                thead: ({ children }) => <thead className="bg-gold-50">{children}</thead>,
                tbody: ({ children }) => <tbody className="divide-y divide-gray-100">{children}</tbody>,
                tr: ({ children }) => <tr className="hover:bg-gold-50/30 transition-colors">{children}</tr>,
                th: ({ children }) => (
                  <th className="text-left px-3 py-2 text-gold-700 text-xs uppercase tracking-wider font-semibold border-b-2 border-gold-300">
                    {children}
                  </th>
                ),
                td: ({ children }) => (
                  <td className="px-3 py-2 text-gray-700 border-b border-gray-100">
                    {children}
                  </td>
                ),
              }}
            >{message.content}</ReactMarkdown>
          </div>
        )}
      </div>
    </div>
  );
}
