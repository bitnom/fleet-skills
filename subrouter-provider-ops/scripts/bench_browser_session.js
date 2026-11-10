// In-page SubRouter benchmark harness.
//
// Use this when the fixed-provider keys are not reachable as local files — for
// example when the keys were created through a browser automation session
// (Playwright MCP, Camoufox, CDP) whose filesystem and loopback are isolated
// from the shell. The keys then stay inside the browser session and the
// timing runs happen in the page, against the same metric definitions that
// scripts/bench_llm_endpoint.py computes.
//
// Usage
//   1. Open the SubRouter console in a logged-in browser session.
//   2. Inject this file into the page (page.evaluate with the file body).
//   3. Call window.__srbench.runProvider('slug', {runs: 3}) per merchant,
//      one merchant per automation call.
//   4. Read window.__srbench.summarize() and the attribution log.
//
// The metric names and the arithmetic mirror bench_llm_endpoint.py exactly so
// the two paths produce comparable numbers.

(() => {
  const DEFAULT_PROMPT =
    'Write a detailed 700-word plain-prose explanation of how TCP congestion ' +
    'control works. No headings, no lists, just continuous prose.';

  const bench = {
    PROMPT: DEFAULT_PROMPT,

    // The session user id. Management calls need it in the New-Api-User
    // header; the session cookie carries the authentication itself.
    userId() {
      try {
        return String(JSON.parse(localStorage.getItem('user') || '{}').id ?? '');
      } catch (e) {
        return '';
      }
    },

    // Management GET/POST from inside the logged-in session.
    async api(path, options = {}) {
      const headers = Object.assign(
        { 'Content-Type': 'application/json', 'New-Api-User': bench.userId() },
        options.headers || {},
      );
      const response = await fetch(path, Object.assign({ credentials: 'include' }, options, { headers }));
      const text = await response.text();
      let body;
      try {
        body = JSON.parse(text);
      } catch (e) {
        body = { _raw: text.slice(0, 300) };
      }
      return { status: response.status, body };
    },

    // GET /api/token/ returns the full key value for every token. Reuse an
    // existing provider:<slug> token instead of creating a duplicate, and pick
    // the newest one when several exist for the same group.
    async getKeys() {
      const result = await bench.api('/api/token/?p=1&size=100');
      const items = (result.body.data && (result.body.data.items || result.body.data)) || [];
      const map = {};
      for (const token of items) {
        if (!token.group || !token.group.startsWith('provider:') || !token.key) continue;
        const slug = token.group.slice('provider:'.length);
        if (!map[slug] || token.id > map[slug].id) map[slug] = { id: token.id, key: token.key, name: token.name };
      }
      return map;
    },

    // POST /api/token/ with a fixed-provider group. Only for merchants that
    // have no such token yet.
    async createFixedToken(slug) {
      return bench.api('/api/token/', {
        method: 'POST',
        body: JSON.stringify({
          name: `${slug}-fixed`,
          group: `provider:${slug}`,
          unlimited_quota: true,
          remain_quota: 0,
          expired_time: -1,
          model_limits_enabled: false,
          model_limits: '',
          subrouter_providers: '',
          subrouter_model_providers: '',
          subrouter_sort_mode: 'token_price_first',
          subrouter_route_preference: 'price_first',
          include_cache_hit_rate: false,
          load_balance_enabled: false,
          include_provider_self: true,
          include_official_channels: false,
          include_shared_subscriptions: false,
        }),
      });
    },

    // The model name a group actually serves can differ from the marketplace
    // listing name. Fetch this after subscribing: an unsubscribed merchant
    // has no group, and the group may not carry the advertised model.
    async groupModels(slug) {
      const result = await bench.api(`/api/user/models?group=provider:${slug}`);
      const data = result.body.data;
      const items = Array.isArray(data) ? data : (data && (data.data || data.items)) || [];
      return items.map((m) => (typeof m === 'string' ? m : m.model_name || m.id || m.name));
    },

    // One streaming request, timed. Mirrors measure_once() in
    // bench_llm_endpoint.py: same fields, same arithmetic, same buffering
    // detection thresholds.
    async measureOnce(key, model, prompt, maxTokens, extraBody) {
      const body = {
        model,
        messages: [{ role: 'user', content: prompt || DEFAULT_PROMPT }],
        max_tokens: maxTokens || 12000,
        stream: true,
      };
      Object.assign(body, extraBody || {});

      const started = performance.now();
      let firstTokenAt = null, firstReasoningAt = null, firstContentAt = null;
      let lastContentAt = null, lastChunkAt = null;
      let usage = null, contentChars = 0, reasoningChars = 0, chunks = 0;
      let status = 0, error = null, modelSeen = null, finishReason = null;

      try {
        const response = await fetch('/v1/chat/completions', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
          body: JSON.stringify(body),
        });
        status = response.status;
        if (!response.ok) {
          error = `HTTP ${status}: ${(await response.text()).slice(0, 300)}`;
        } else {
          const reader = response.body.getReader();
          const decoder = new TextDecoder();
          let buffer = '';
          for (;;) {
            const { done, value } = await reader.read();
            if (done) break;
            buffer += decoder.decode(value, { stream: true });
            let index;
            while ((index = buffer.indexOf('\n')) >= 0) {
              const line = buffer.slice(0, index).trim();
              buffer = buffer.slice(index + 1);
              if (!line.startsWith('data:')) continue;
              const payload = line.slice(5).trim();
              if (!payload || payload === '[DONE]') continue;
              let chunk;
              try {
                chunk = JSON.parse(payload);
              } catch (e) {
                continue;
              }
              chunks += 1;
              lastChunkAt = performance.now();
              if (chunk.usage) usage = chunk.usage;
              if (chunk.model) modelSeen = chunk.model;
              const choices = chunk.choices || [];
              if (!choices.length) continue;
              const choice = choices[0];
              if (choice.finish_reason) finishReason = choice.finish_reason;
              const delta = choice.delta || {};
              const text = delta.content || '';
              const reasoning = delta.reasoning_content || '';
              if (text || reasoning) {
                if (firstTokenAt === null) firstTokenAt = performance.now();
              }
              if (reasoning) {
                if (firstReasoningAt === null) firstReasoningAt = performance.now();
                reasoningChars += reasoning.length;
              }
              if (text) {
                if (firstContentAt === null) firstContentAt = performance.now();
                lastContentAt = performance.now();
                contentChars += text.length;
              }
            }
          }
        }
      } catch (e) {
        error = `${e && e.constructor ? e.constructor.name : 'Error'}: ${e.message}`;
      }

      const ended = lastChunkAt !== null ? lastChunkAt : performance.now();
      let completionTokens = usage ? usage.completion_tokens || 0 : 0;
      let reasoningTokens = 0;
      if (usage) {
        const details = usage.completion_tokens_details;
        if (details && details.reasoning_tokens != null) reasoningTokens = details.reasoning_tokens;
        else if (usage.completion_thinking_tokens != null) reasoningTokens = usage.completion_thinking_tokens;
        else if (usage.reasoning_tokens != null) reasoningTokens = usage.reasoning_tokens;
      }
      // Some merchants report reasoning inside completion_tokens but leave
      // reasoning_tokens at 0, and some report no usage at all. Estimate from
      // characters so the throughput column stays comparable.
      const tokensEstimated = !usage && completionTokens === 0;
      if (tokensEstimated && contentChars) {
        completionTokens = Math.max(1, Math.floor(contentChars / 4));
        reasoningTokens = 0;
      }

      const totalMs = Math.round(ended - started);
      const generationS = firstTokenAt === null ? null : Math.max(0, (ended - firstTokenAt) / 1000);
      const contentS =
        firstContentAt === null || lastContentAt === null
          ? null
          : (lastContentAt - firstContentAt) / 1000;
      const tpsEffective = !generationS || generationS <= 0 ? null : Number((completionTokens / generationS).toFixed(2));
      const contentTokens = Math.max(0, completionTokens - reasoningTokens);
      const tpsContent = !contentS || contentS <= 0 ? null : Number((contentTokens / contentS).toFixed(2));
      const chunkRate =
        !generationS || generationS <= 0 || chunks < 2 ? null : Number(((chunks - 1) / generationS).toFixed(1));
      const deliveredRatio =
        !totalMs || generationS === null ? null : Number((generationS / (totalMs / 1000)).toFixed(3));
      let burst = false;
      if (chunkRate !== null && chunkRate > 1000) burst = true;
      else if (deliveredRatio !== null && deliveredRatio < 0.25 && chunkRate !== null && chunkRate > 50) burst = true;
      const tpsWall = !totalMs || totalMs <= 0 ? null : Number((completionTokens / (totalMs / 1000)).toFixed(2));

      const estTotalTokens = Math.floor((contentChars + reasoningChars) / 4);
      const estContentTokens = Math.floor(contentChars / 4);

      return {
        status,
        error,
        modelSeen,
        chunks,
        finishReason,
        truncated: finishReason === 'length',
        no_content: error === null && firstContentAt === null,
        ttft_ms: firstTokenAt === null ? null : Math.round(firstTokenAt - started),
        ttft_reasoning_ms: firstReasoningAt === null ? null : Math.round(firstReasoningAt - started),
        ttft_content_ms: firstContentAt === null ? null : Math.round(firstContentAt - started),
        total_ms: totalMs,
        generation_s: generationS === null ? null : Number(generationS.toFixed(3)),
        content_window_s: contentS === null ? null : Number(contentS.toFixed(3)),
        completion_tokens: completionTokens,
        reasoning_tokens: reasoningTokens,
        content_tokens: contentTokens,
        tokens_estimated: tokensEstimated,
        tps_effective: tpsEffective,
        tps_content: tpsContent,
        tps_wall: tpsWall,
        chunk_rate: chunkRate,
        delivered_ratio: deliveredRatio,
        burst,
        content_chars: contentChars,
        reasoning_chars: reasoningChars,
        // Character-based cross-check, independent of the gateway's token accounting.
        est_total_tokens: estTotalTokens,
        est_content_tokens: estContentTokens,
        tps_total_est: generationS && generationS > 0 ? Number((estTotalTokens / generationS).toFixed(2)) : null,
        tps_content_est: contentS && contentS > 0 ? Number((estContentTokens / contentS).toFixed(2)) : null,
      };
    },

    results: {},

    // Sequential runs against one merchant. Never run two merchants at once:
    // parallel calls contend for shared upstream quota and distort the number.
    async runProvider(slug, options = {}) {
      const runs = options.runs || 3;
      const delayMs = options.delayMs === undefined ? 1500 : options.delayMs;
      const model = options.model || 'deepseek-v4.1-flash-1017';
      const maxTokens = options.maxTokens || 12000;
      const extraBody = options.extraBody || { reasoning_effort: 'max' };
      const keys = await bench.getKeys();
      const token = keys[slug];
      if (!token) throw new Error(`no fixed-provider token for ${slug}; create one first`);
      const results = [];
      for (let i = 0; i < runs; i += 1) {
        const result = await bench.measureOnce(token.key, model, options.prompt || DEFAULT_PROMPT, maxTokens, extraBody);
        result.run = i + 1;
        result.provider = slug;
        result.max_tokens = maxTokens;
        results.push(result);
        if (i < runs - 1) await new Promise((resolve) => setTimeout(resolve, delayMs));
      }
      bench.results[slug] = results;
      return results;
    },

    // Medians with spread, over the valid runs only.
    summarize() {
      const median = (values) => {
        const clean = values.filter((v) => v !== null && v !== undefined && !Number.isNaN(v)).sort((a, b) => a - b);
        if (!clean.length) return null;
        const mid = Math.floor(clean.length / 2);
        return clean.length % 2 ? clean[mid] : Number(((clean[mid - 1] + clean[mid]) / 2).toFixed(2));
      };
      const summary = {};
      for (const slug of Object.keys(bench.results)) {
        const all = bench.results[slug];
        const ok = all.filter((r) => !r.error && r.ttft_content_ms !== null);
        const failed = all.filter((r) => r.error || r.ttft_content_ms === null);
        const pick = (key) => ok.map((r) => r[key]);
        const span = (key) => {
          const values = pick(key);
          return values.length ? { min: Math.min(...values), max: Math.max(...values) } : null;
        };
        summary[slug] = {
          n_valid: ok.length,
          n_failed: failed.length,
          failures: failed.map((r) => r.error || 'no visible content'),
          tps_effective: { median: median(pick('tps_effective')), ...span('tps_effective') },
          tps_total_est: { median: median(pick('tps_total_est')), ...span('tps_total_est') },
          tps_content_est: { median: median(pick('tps_content_est')), ...span('tps_content_est') },
          tps_wall: { median: median(pick('tps_wall')), ...span('tps_wall') },
          ttft_ms: { median: median(pick('ttft_ms')), ...span('ttft_ms') },
          ttft_content_ms: { median: median(pick('ttft_content_ms')), ...span('ttft_content_ms') },
          total_ms: { median: median(pick('total_ms')) },
          burst_runs: ok.filter((r) => r.burst).length,
          model_seen: [...new Set(ok.map((r) => r.modelSeen))],
          finish_reason: [...new Set(ok.map((r) => r.finishReason))],
        };
      }
      return summary;
    },

    // Attribution: the gateway log proves which merchant served each request.
    // Only non-secret fields come back.
    async attribution(modelFilter) {
      const result = await bench.api('/api/log/self?p=1&page_size=100');
      const rows = (result.body.data && (result.body.data.items || result.body.data)) || [];
      return rows
        .filter((r) => !modelFilter || (r.model_name || '').includes(modelFilter))
        .map((r) => {
          let other = {};
          try {
            other = typeof r.other === 'string' ? JSON.parse(r.other) : r.other || {};
          } catch (e) {
            other = {};
          }
          return {
            created_at: r.created_at,
            type: r.type,
            group: r.group,
            model: r.model_name,
            prompt_tokens: r.prompt_tokens,
            completion_tokens: r.completion_tokens,
            use_time: r.use_time,
            frt: other.frt,
            provider_slug: other.provider_slug,
            reasoning_effort: other.reasoning_effort,
          };
        })
        .sort((a, b) => (b.created_at || 0) - (a.created_at || 0));
    },
  };

  window.__srbench = bench;
  return 'installed';
})();
