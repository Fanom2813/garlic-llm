// OpenAI-compatible API jobs (api.c queues them; included in main.c, so it sees the engine and the conversation).
// A job runs on the model between the chat's turns: the request's messages are the whole conversation, so the
// conversation on screen is cleared, and the reply is written to the connection (whole, or as server-sent events).
// The reply is generated as the chat generates its own: several tokens per step with the MTP head where the app has
// it (GARLIC_SPEC), and Circle on the controller stops it. What the screen shows meanwhile is main.c's part
// (api_chat_begin / _reply / _step / _end).

#define API_IDS 16384             // tokens a job's prompt may have: the longest context of the app
#define API_TAIL 32               // kept free for the assistant's turn after the messages (at most 17 tokens)
static uint32_t api_ids[API_IDS];   // the prompt of a job

// How many bytes at the start of p (n) are whole UTF-8 characters (the rest waits for the next token).
static size_t api_utf8_whole(const uint8_t* p, size_t n) {
    size_t i = n;
    for (int back = 1; back <= 4 && i > 0; back++) {
        i--;
        uint8_t c = p[i];
        if ((c & 0xC0) == 0x80) continue;   // a continuation byte: keep looking for its lead byte
        size_t need = c < 0x80 ? 1 : (c >> 5) == 6 ? 2 : (c >> 4) == 14 ? 3 : (c >> 3) == 30 ? 4 : 1;
        return back < (int)need ? i : n;
    }
    return n;
}

// one server-sent event; -1 if the client went away
static int api_send_event(int fd, const char* json) {
    Sb s;
    sb_init(&s);
    sb_str(&s, "data: ");
    sb_str(&s, json);
    sb_str(&s, "\n\n");
    int r = s.p && !s.oom ? api_send(fd, s.p, s.n) : -1;
    sb_free(&s);
    return r;
}

// Builds the prompt: each message as <|im_start|>role\ncontent<|im_end|>\n, then the assistant's turn with the empty
// thought block (as the chat does, enable_thinking=false). Returns the number of ids, -1 if a message is malformed,
// or -2 if the messages do not fit API_IDS. The limit counts tokens, not bytes: a long conversation may use the
// whole context. (Every token stands for one byte or more, so the tail after the messages always fits API_TAIL.)
static int api_prompt(const JNode* pool, const ChatRequest* cr) {
    const int cap = API_IDS - API_TAIL;   // where the messages must end
    int n = 0;
    for (int m = pool[cr->messages].first; m >= 0; m = pool[m].next) {
        Sb content;
        sb_init(&content);
        char role[16] = "user";
        int ok = api_message(pool, m, role, sizeof(role), &content) == 0;
        if (!ok || content.oom) {
            sb_free(&content);
            return -1;
        }
        if (strcmp(role, "system") && strcmp(role, "assistant") && strcmp(role, "user") && strcmp(role, "tool"))
            strcpy(role, "user");
        if (n >= cap) {
            sb_free(&content);
            return -2;
        }
        api_ids[n++] = IM_START;
        n = encode_into(api_ids, n, cap, role);
        n = encode_into(api_ids, n, cap, "\n");
        if (content.p) n = encode_into(api_ids, n, cap, content.p);
        sb_free(&content);
        if (n + 2 > cap) return -2;   // the text filled what was left (it may have been cut): too long
        api_ids[n++] = IM_END;
        n = encode_into(api_ids, n, cap, "\n");
    }
    api_ids[n++] = IM_START;
    n = encode_into(api_ids, n, API_IDS, "assistant\n");
    if (eng.qwen35) {
        api_ids[n++] = THINK;
        n = encode_into(api_ids, n, API_IDS, "\n\n");
        api_ids[n++] = THINK_END;
        n = encode_into(api_ids, n, API_IDS, "\n\n");
    }
    return n;
}

static void api_error(int fd, const char* status_line, const char* message, const char* type, const char* code) {
    Sb s;
    sb_init(&s);
    api_json_error(&s, message, type, code);
    Sb h;
    sb_init(&h);
    sb_str(&h, status_line);
    sb_str(&h, "\r\nContent-Type: application/json\r\nContent-Length: ");
    sb_int(&h, (long long)s.n);
    sb_str(&h, "\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n");
    if (h.p && s.p && api_send(fd, h.p, h.n) == 0) api_send(fd, s.p, s.n);
    sb_free(&h);
    sb_free(&s);
}

static void api_job(ApiJob* job) {
    static unsigned api_count;
    JNode* pool = malloc(sizeof(JNode) * API_MAX_NODES);
    ChatRequest cr;
    const char* err = NULL;
    if (!pool || api_chat_parse(job->body, job->body_len, pool, API_MAX_NODES, &cr, &err)) {
        free(pool);
        api_error(job->fd, "HTTP/1.1 400 Bad Request", err ? err : "Out of memory.", "invalid_request_error",
                  "invalid_body");
        return;
    }
    int n = api_prompt(pool, &cr);
    if (n == -1) {
        free(pool);
        api_error(job->fd, "HTTP/1.1 400 Bad Request", "A message is malformed: it needs a 'role', and 'content' must "
                  "be a string or an array of parts.", "invalid_request_error", "invalid_body");
        return;
    }
    if (n < 0) {
        free(pool);
        api_error(job->fd, "HTTP/1.1 400 Bad Request", "The messages do not fit the context window.",
                  "invalid_request_error", "context_length_exceeded");
        return;
    }
    free(pool);
    if (n + cr.max_tokens + 2 > (int)eng.ctx_limit) {
        api_error(job->fd, "HTTP/1.1 400 Bad Request", "The messages and max_tokens do not fit the context window.",
                  "invalid_request_error", "context_length_exceeded");
        return;
    }
    // the model answers this request: the conversation on screen starts again from nothing (a request refused
    // above leaves it as it was)
    pos = 0;
    need_close = 0;
    hist_n = hist_done = 0;
    thinking = think_turn = 0;
    sys_pre = 0;
    view.scroll = 0;
    api_chat_begin();   // (clears the conversation: a note says that a request is being answered)
    if (cr.has_seed) seed = cr.seed;
    char id[32];
    snprintf(id, sizeof(id), "chatcmpl-%u", ++api_count);
    const char* model = api_model();
    long long created = (long long)time(NULL);
    say("api: prompt of %d tokens, up to %d new, T %.2f%s", n, cr.max_tokens, cr.temperature,
        cr.stream ? ", streamed" : "");
    engine_reset(&eng);
    if (engine_run(&eng, api_ids, n, 0, (float)cr.temperature, seed++, &next_token)) {
        api_error(job->fd, "HTTP/1.1 500 Internal Server Error", eng.error, "server_error", NULL);
        pos = 0;
        api_chat_end();
        return;
    }
    pos = n;

    int fd = job->fd, streamed = 0, client_gone = 0, error = 0;
    if (cr.stream) {
        const char* h = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n"
                        "Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n";
        if (api_send(fd, h, strlen(h))) client_gone = 1;
        streamed = 1;
        Sb first;
        sb_init(&first);
        api_json_chunk(&first, id, model, created, "assistant", "", 0, NULL);
        if (!client_gone && first.p && api_send_event(fd, first.p)) client_gone = 1;
        sb_free(&first);
    }

    Sb text, pend;   // the reply (all of it), and the bytes of the last tokens not yet a whole character
    sb_init(&text);
    sb_init(&pend);
    int produced = 0, stopped = 0;
    const char* finish = "length";
    // The tokens to write: the one a step drew, after those it kept from the MTP head's draft (the model has read
    // these already). Without the head a step is one token.
    uint32_t q[9];
    int nq = 1, iq = 0;
    q[0] = next_token;
    double t0 = now();
    api_chat_reply();
    while (produced < cr.max_tokens) {
        uint32_t t = q[iq++];
        if (t == IM_END || t == eng.eos2 || t == eng.eos) {
            finish = "stop";
            break;
        }
        const uint8_t* bytes = NULL;
        int nb = tok_piece(&tok, t, &bytes);
        produced++;
        if (nb > 0) {
            sb_add(&text, (const char*)bytes, nb);
            sb_add(&pend, (const char*)bytes, nb);
        }
        if (streamed && pend.n) {
            size_t whole = api_utf8_whole((const uint8_t*)pend.p, pend.n);
            if (whole) {
                Sb ev;
                sb_init(&ev);
                api_json_chunk(&ev, id, model, created, NULL, pend.p, whole, NULL);
                if (ev.p && api_send_event(fd, ev.p)) client_gone = 1;
                sb_free(&ev);
                memmove(pend.p, pend.p + whole, pend.n - whole);
                pend.n -= whole;
                pend.p[pend.n] = 0;
            }
        }
        if (client_gone || produced == cr.max_tokens) break;
        if (iq < nq) continue;   // (the next token is one the last step kept)
        if (api_chat_step(produced)) {   // Circle: the reply ends here, cut short as by max_tokens
            stopped = 1;
            break;
        }
        int ne = 0;   // tokens of the draft this step keeps
#ifdef GARLIC_SPEC
        if (spec_active(&eng)) {   // (never more than max_tokens: the step keeps at most what is left of them)
            if (engine_spec_step(&eng, t, pos, (float)cr.temperature, seed++, cr.max_tokens - produced + 1, q, &ne,
                                 &next_token)) {
                error = 1;
                break;
            }
        } else
#endif
        if (engine_run(&eng, &t, 1, pos, (float)cr.temperature, seed++, &next_token)) {
            error = 1;
            break;
        }
        pos += 1 + ne;
        q[ne] = next_token;
        nq = ne + 1, iq = 0;
    }
    double dt = now() - t0;
    say("api: %d tokens in %.1f s (%.1f tokens/s), %s", produced, dt, dt > 0 ? produced / dt : 0.0,
        error ? "engine error" : stopped ? "stopped on the console" : finish);

    if (streamed) {
        if (!client_gone && !error) {
            Sb last;
            sb_init(&last);
            api_json_chunk(&last, id, model, created, NULL, "", 0, finish);
            if (last.p) api_send_event(fd, last.p);
            sb_free(&last);
            api_send(fd, "data: [DONE]\n\n", 14);
        }
        if (error && !client_gone) {   // the headers are out: the error goes in the stream
            Sb e;
            sb_init(&e);
            api_json_error(&e, eng.error, "server_error", NULL);
            if (e.p) api_send_event(fd, e.p);
            sb_free(&e);
        }
    } else if (error) {
        api_error(fd, "HTTP/1.1 500 Internal Server Error", eng.error, "server_error", NULL);
    } else {
        Sb body, head;
        sb_init(&body);
        sb_init(&head);
        // a reply cut short (max_tokens, Circle) may end inside a character: those bytes are left out, as in a stream,
        // so the JSON stays valid UTF-8
        size_t tn = text.p ? api_utf8_whole((const uint8_t*)text.p, text.n) : 0;
        api_json_completion(&body, id, model, created, text.p ? text.p : "", tn, finish, n, produced);
        sb_str(&head, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ");
        sb_int(&head, (long long)body.n);
        sb_str(&head, "\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n");
        if (head.p && body.p && api_send(fd, head.p, head.n) == 0) api_send(fd, body.p, body.n);
        sb_free(&body);
        sb_free(&head);
    }
    sb_free(&text);
    sb_free(&pend);
    // the engine's state is this request's; the conversation on screen starts again at position 0
    pos = 0;
    need_close = 0;
    api_chat_end();
}

// ---- /v1/raw: token ids in, token ids out, with a prompt cache (server mode) -------------------------------------
// For a client that does its own chat template and tokenizing (the PS4 is only the inference engine).
// Body (little endian): "GRW1", uint32 n_tokens, max_new, float temperature, uint32 seed, n_stop, flags (bit 0: do
// not use the cache), then n_stop stop ids and n_tokens prompt ids. Generation also stops at <|im_end|> and the eos.
// Reply: text/plain, one line per event, flushed as it happens:
//   "c <reused> <prompt>"            how many prompt tokens came from the cache
//   "p <read> <seconds>"             the rest of the prompt was read in this time
//   "t <id> [<id> ...]"              generated tokens (several when the MTP head's drafts were kept)
//   "d <stop|length|cancel> <n> <seconds>"   the end: tokens generated and decode time
//   "e <message>"                    an error (then the reply ends)
// Prompt cache: raw_ids holds every token the engine has read (prompt and generated, in order); a new prompt that
// starts with all of them only reads its new tokens. Otherwise, if it starts with the previous prompt, the DeltaNet
// state saved at the end of that prompt is put back (Qwen3.5's recurrent layers cannot simply be cut back). Else the
// prompt is read from the start. Anything else that moves the engine (a chat turn, a /v1/chat job) clears the cache.

static uint32_t raw_ids[API_IDS];
static int raw_n = -1;            // tokens the engine has read for the cache; -1: the cache is not valid
static int raw_snap_n = -1;       // the DeltaNet state at this position is saved in raw_snap
static uint64_t raw_snap;         // GPU block for that copy (main.c allocates it in server mode); 0: none
// A second copy at the end of the system prompt (its first <|im_start|> after the start): a new conversation of the
// same agent repeats the system prompt but not the turns after it. Valid while no request reads positions before it.
static int raw_sys_n = -1;
static uint64_t raw_sys;
#define RAW_SYS_MIN 512           // (shorter system prompts are quick to read again)

static void raw_invalidate(void) { raw_n = raw_snap_n = raw_sys_n = -1; }

static int raw_line(int fd, const char* s) { return api_send(fd, s, strlen(s)); }

static void api_raw_job(ApiJob* job) {
    const uint8_t* b = (const uint8_t*)job->body;
    uint32_t h[6];
    memcpy(h, b + 4, sizeof(h));
    int n = (int)h[0], max_new = (int)h[1], n_stop = (int)h[4], no_cache = h[5] & 1;
    float temperature;
    memcpy(&temperature, &h[2], 4);
    uint32_t rseed = h[3];
    uint32_t stops[64];
    memcpy(stops, b + 28, 4ull * n_stop);
    const uint32_t* toks = (const uint32_t*)(b + 28 + 4 * n_stop);   // (body is malloc'd: aligned)
    int fd = job->fd;
    const char* hdr = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nCache-Control: no-cache\r\n"
                      "Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n";
    if (api_send(fd, hdr, strlen(hdr))) return;
    char line[256];
    if (n > API_IDS - 2 || n + max_new + 2 > (int)eng.ctx_limit) {
        snprintf(line, sizeof(line), "e prompt (%d) + max_new (%d) does not fit the context (%u)\n", n, max_new,
                 eng.ctx_limit);
        raw_line(fd, line);
        return;
    }
    for (int i = 0; i < n; i++)
        if (toks[i] >= tok.n_vocab) {
            snprintf(line, sizeof(line), "e token %u at %d is not in the vocabulary (%u)\n", toks[i], i, tok.n_vocab);
            raw_line(fd, line);
            return;
        }
    // how much of the prompt the engine has read already
    int start = 0;
    if (!no_cache && raw_n >= 0) {
        int c = 0;
        while (c < raw_n && c < n && raw_ids[c] == toks[c]) c++;
        if (c == raw_n && c < n) {
            start = c;   // the prompt goes on from everything read so far
        } else {         // back to the end of the last prompt, or else to the end of the system prompt
            int at = -1;
            uint64_t from = 0;
            if (raw_snap && raw_snap_n > 0 && raw_snap_n <= c && raw_snap_n < n) at = raw_snap_n, from = raw_snap;
            if (raw_sys && raw_sys_n > at && raw_sys_n <= c && raw_sys_n < n) at = raw_sys_n, from = raw_sys;
            if (at > 0 && engine_state_copy(&eng, from, 0) == 0) start = at;
        }
    }
    if (start < raw_sys_n) raw_sys_n = -1;   // (this request writes over positions before it)
    if (start == 0) engine_reset(&eng);
    hist_n = hist_done = 0;   // (nothing of the chat is read in the background after this)
    thinking = think_turn = 0;
    need_close = 0;
    sys_pre = 0;
    api_chat_begin();
    snprintf(line, sizeof(line), "c %d %d\n", start, n);
    int client_gone = raw_line(fd, line) != 0;
    say("raw: prompt %d tokens, %d from the cache, up to %d new, T %.2f", n, start, max_new, temperature);
    double t0 = now();
    raw_n = -1;   // (not valid while the engine moves)
#ifdef GARLIC_SERVER
    sv.prompt_n = n, sv.cached_n = start, sv.prompt_done = 0;
    sv.requests++;
    sv.tokens_in += (unsigned long long)n, sv.tokens_cached += (unsigned long long)start;
    srv_draw(1);
    // the prompt in pieces, so the dashboard shows how far it has got (the engine reads it the same way)
    int pf_err = 0;
    // The state is also saved just before the prompt's last <|im_start|> (the reply's header): the next request
    // repeats the conversation up to there, but renders this turn's ending (<think> and so on) differently, so the
    // saved state at the very end would not match it.
    int snap_at = -1, snapped = -1;
    raw_snap_n = -1;
    if (raw_snap)
        for (int i = n - 1; i > start; i--)
            if (toks[i] == eng.im_start) {
                snap_at = i;
                break;
            }
    int sys_at = -1, sys_snapped = -1;
    if (raw_sys && raw_sys_n < 0)
        for (int i = 1; i < n; i++)
            if (toks[i] == eng.im_start) {
                if (i > start && i >= RAW_SYS_MIN) sys_at = i;
                break;
            }
    for (int i = start; i < n && !pf_err;) {
        int lim = n;
        if (sys_at > i && sys_at < lim) lim = sys_at;
        if (snap_at > i && snap_at < lim) lim = snap_at;
        int k = lim - i > 256 ? 256 : lim - i;
        pf_err = engine_run(&eng, toks + i, k, i, temperature, rseed, &next_token);
        i += k;
        if (!pf_err && i == sys_at && engine_state_copy(&eng, raw_sys, 1) == 0) sys_snapped = i;
        if (!pf_err && i == snap_at && engine_state_copy(&eng, raw_snap, 1) == 0) snapped = i;
        sv.prompt_done = i - start;
        double el = now() - t0;
        if (el > 0) sv.prompt_tok_s = (float)(sv.prompt_done / el);
        srv_draw(0);
    }
    if (pf_err) {
#else
    if (engine_run(&eng, toks + start, n - start, start, temperature, rseed, &next_token)) {
#endif
        snprintf(line, sizeof(line), "e %s\n", eng.error);
        raw_line(fd, line);
        raw_invalidate();
        api_chat_end();
        return;
    }
    pos = n;
    memcpy(raw_ids, toks, 4ull * n);
    raw_n = n;
#ifdef GARLIC_SERVER
    if (sys_snapped > 0) raw_sys_n = sys_snapped;
    if (snapped > 0) raw_snap_n = snapped;
    else
#endif
    if (raw_snap && engine_state_copy(&eng, raw_snap, 1) == 0) raw_snap_n = n;
    else raw_snap_n = -1;
    double t_pf = now() - t0;
    snprintf(line, sizeof(line), "p %d %.3f\n", n - start, t_pf);
    if (!client_gone && raw_line(fd, line)) client_gone = 1;

    uint32_t q[9];
    int nq = 1, iq = 0, produced = 0, error = 0;
    const char* finish = "length";
    q[0] = next_token;
    double t1 = now();
    api_chat_reply();
    Sb out;
    sb_init(&out);
    while (produced < max_new && !client_gone) {
        uint32_t t = q[iq++];
        int is_stop = t == IM_END || t == eng.eos || t == eng.eos2;
        for (int i = 0; i < n_stop && !is_stop; i++) is_stop = t == stops[i];
        if (is_stop) {   // (the stop token is sent, not read: the next prompt may go on with it)
            snprintf(line, sizeof(line), "t %u\n", t);
            if (raw_line(fd, line)) client_gone = 1;
            finish = "stop";
            break;
        }
        produced++;
        // tokens of this step go out together
        if (!out.n) sb_str(&out, "t");
        snprintf(line, sizeof(line), " %u", t);
        sb_str(&out, line);
        if (iq < nq) continue;   // (the next token is a kept draft: already read)
        sb_str(&out, "\n");
        if (out.p && api_send(fd, out.p, out.n)) client_gone = 1;
        out.n = 0;
        if (client_gone || produced >= max_new) break;
        if (api_chat_step(produced)) {
            finish = "cancel";
            break;
        }
        int ne = 0;
#ifdef GARLIC_SPEC
        if (spec_active(&eng)) {
            if (engine_spec_step(&eng, t, pos, temperature, rseed++, max_new - produced + 1, q, &ne, &next_token)) {
                error = 1;
                break;
            }
        } else
#endif
        if (engine_run(&eng, &t, 1, pos, temperature, rseed++, &next_token)) {
            error = 1;
            break;
        }
        raw_ids[pos] = t;   // what the engine read: t, then the drafts it kept
        for (int i = 0; i < ne; i++) raw_ids[pos + 1 + i] = q[i];
        pos += 1 + ne;
        raw_n = pos;
        q[ne] = next_token;
        nq = ne + 1, iq = 0;
    }
    if (out.n && !client_gone) {   // tokens still waiting (stopped by max_new between drafts)
        sb_str(&out, "\n");
        if (out.p) api_send(fd, out.p, out.n);
    }
    sb_free(&out);
    double dt = now() - t1;
#ifdef GARLIC_SERVER
    sv.generated_n = produced;
    sv.last_tok_s = dt > 0 ? (float)(produced / dt) : 0.0f;
    sv.tokens_out += (unsigned long long)produced;
    if (t_pf > 0) sv.prompt_tok_s = (float)((n - start) / t_pf);
#endif
    if (error) {
        snprintf(line, sizeof(line), "e %s\n", eng.error);
        raw_invalidate();
    } else {
        snprintf(line, sizeof(line), "d %s %d %.3f\n", finish, produced, dt);
    }
    if (!client_gone) raw_line(fd, line);
    say("raw: %d tokens in %.1f s (%.1f tokens/s, prompt read %.1f s), %s", produced, dt,
        dt > 0 ? produced / dt : 0.0, t_pf, error ? "engine error" : finish);
    api_chat_end();
}
