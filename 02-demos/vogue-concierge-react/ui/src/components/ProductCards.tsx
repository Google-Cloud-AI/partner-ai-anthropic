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

import { ShoppingBag, Tag } from 'lucide-react';

interface Product {
  sku: string; name: string; price: number; category: string;
  description: string; color?: string; material?: string; image_url?: string;
}

export default function ProductCards({ products }: { products: Product[] }) {
  if (!products || products.length === 0) return null;
  return (
    <div className="ml-11 mb-4">
      <div className="flex gap-3 overflow-x-auto pb-2">
        {products.map((product) => (
          <div key={product.sku} className="flex-shrink-0 w-56 bg-white border border-gray-200 rounded-xl overflow-hidden hover:border-gold-400 hover:shadow-lg hover:shadow-gold-400/10 transition-all duration-500 group">
            <div className="relative h-56 bg-gray-100 overflow-hidden">
              {product.image_url ? (
                <img src={product.image_url} alt={product.name} className="w-full h-full object-cover group-hover:scale-105 transition-transform duration-700" loading="lazy" />
              ) : (
                <div className="w-full h-full flex items-center justify-center"><ShoppingBag size={32} className="text-gray-300" /></div>
              )}
              <div className="absolute top-2 left-2 px-2 py-0.5 bg-white/90 backdrop-blur-sm rounded-full text-[10px] text-gray-600 uppercase tracking-wider">{product.category}</div>
              <div className="absolute top-2 right-2 px-2 py-0.5 bg-gold-400/90 backdrop-blur-sm rounded-full text-[10px] text-white font-medium">{product.sku}</div>
            </div>
            <div className="p-3">
              <h4 className="font-display text-sm font-medium text-gray-900 leading-tight mb-1 group-hover:text-gold-600 transition-colors duration-300">{product.name}</h4>
              <div className="flex items-center justify-between mb-2">
                <span className="text-gold-600 font-semibold text-sm">${product.price.toLocaleString()}</span>
                {product.material && <span className="text-[10px] text-gray-400 uppercase tracking-wide">{product.material}</span>}
              </div>
              {product.color && <div className="flex items-center gap-1.5 text-[10px] text-gray-400"><Tag size={10} /><span>{product.color}</span></div>}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
