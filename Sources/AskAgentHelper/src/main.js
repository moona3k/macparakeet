import { createInterface } from 'node:readline';
import { createHash } from 'node:crypto';
import { runAgentLoop } from '@earendil-works/pi-agent-core';
import { Type, createAssistantMessageEventStream } from '@earendil-works/pi-ai';

const VERSION = 1;
const MAX_FRAME = 64 * 1024;
const MAX_TURNS = 12;
const MAX_INPUT_CHARS = 384_000;
const MAX_REQUEST_CHARS = 32_000;
const MAX_TOOL_CHARS = 32_768;
const MAX_EVIDENCE_CHARS = 131_072;
const MAX_OUTPUT_CHARS = 80_000;
const DEADLINE_MS = 180_000;
const allowed = new Set(['list_sources', 'search', 'read', 'get_summary']);
const cost = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 };
const zeroUsage = () => ({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost });
const object = (v) => v && typeof v === 'object' && !Array.isArray(v);

const schemas = {
  list_sources: Type.Object({}, { additionalProperties: false }),
  search: Type.Object({ query: Type.String({ minLength: 1 }), sourceID: Type.Optional(Type.String({ minLength: 1 })), limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 12 })) }, { additionalProperties: false }),
  read: Type.Object({ sourceID: Type.String({ minLength: 1 }), start: Type.Integer({ minimum: 0 }), limit: Type.Integer({ minimum: 1, maximum: 12 }) }, { additionalProperties: false }),
  get_summary: Type.Object({ sourceID: Type.String({ minLength: 1 }) }, { additionalProperties: false }),
};
const descriptions = {
  list_sources: 'List metadata for the selected sources.',
  search: 'Search only the selected source transcripts for a phrase.',
  read: 'Read a bounded passage from one selected source.',
  get_summary: 'Get a current summary for one selected source, if available.',
};

const state = { started: false, runID: null, scopeID: null, pending: new Map(), nextID: 0, abort: new AbortController(), outputChars: 0, inputChars: 0, evidenceChars: 0, turns: 0, finalText: '' };
function fail(message) {
  if (!state.abort.signal.aborted) state.abort.abort(new Error(message));
  throw new Error(message);
}
function write(kind, requestID, data = {}) {
  const frame = { v: VERSION, kind, runID: state.runID, scopeID: state.scopeID, requestID, ...data };
  const encoded = JSON.stringify(frame);
  if (Buffer.byteLength(encoded) > MAX_FRAME) fail('Outgoing frame exceeds limit');
  process.stdout.write(encoded + '\n');
}
function request(kind, data = {}, onChunk) {
  if (state.abort.signal.aborted) return Promise.reject(state.abort.signal.reason);
  const requestID = `${state.runID}:${++state.nextID}`;
  return new Promise((resolve, reject) => {
    state.pending.set(requestID, { kind, resolve, reject, onChunk });
    state.abort.signal.addEventListener('abort', () => { state.pending.delete(requestID); reject(state.abort.signal.reason); }, { once: true });
    write(kind, requestID, data);
  });
}
function validateReply(frame) {
  if (!object(frame) || frame.v !== VERSION || frame.runID !== state.runID || frame.scopeID !== state.scopeID || typeof frame.requestID !== 'string') fail('Invalid reply identity');
  const pending = state.pending.get(frame.requestID);
  if (!pending) fail('Unknown reply request ID');
  if (frame.kind === 'modelChunk') {
    if (pending.kind !== 'modelFinal' || typeof frame.text !== 'string') fail('Invalid model chunk');
    pending.onChunk?.(frame.text);
    return;
  }
  const expected = { modelDecision: 'decision', modelFinal: 'modelDone', tool: 'toolResult' }[pending.kind];
  if (frame.kind !== expected && frame.kind !== 'error') fail('Wrong reply kind');
  state.pending.delete(frame.requestID);
  if (frame.kind === 'error') pending.reject(new Error(typeof frame.message === 'string' ? frame.message : 'Host failed'));
  else pending.resolve(frame);
}
function compactMessages(messages) {
  return messages.map((m) => {
    if (m.role === 'system' || m.role === 'user') return { role: m.role, content: typeof m.content === 'string' ? m.content : m.content.filter((c) => c.type === 'text').map((c) => c.text).join('\n') };
    if (m.role === 'toolResult') return { role: 'user', content: `Tool ${m.toolName} result: ${m.content.filter((c) => c.type === 'text').map((c) => c.text).join('\n')}` };
    if (m.role === 'assistant') return { role: 'assistant', content: (typeof m.content === 'string' ? [{ type: 'text', text: m.content }] : m.content).map((c) => c.type === 'toolCall' ? `Called ${c.name}(${JSON.stringify(c.arguments)})` : c.type === 'text' ? c.text : '').filter(Boolean).join('\n') };
    throw new Error('Unexpected Pi message role');
  });
}
function piMessage(content, stopReason) {
  return { role: 'assistant', content, api: 'openai-completions', provider: 'macparakeet', model: 'configured', usage: zeroUsage(), stopReason, timestamp: Date.now() };
}
function emitPi(stream, message) {
  stream.push({ type: 'start', partial: message });
  stream.push({ type: 'done', reason: message.stopReason, message });
}
function rejectPi(stream, error) {
  const message = { ...piMessage([], state.abort.signal.aborted ? 'aborted' : 'error'), errorMessage: error instanceof Error ? error.message : String(error) };
  stream.push({ type: 'error', reason: message.stopReason, error: message });
}
function streamFn(_model, context) {
  const stream = createAssistantMessageEventStream();
  void (async () => {
    try {
      if (++state.turns > MAX_TURNS) fail('Ask turn limit reached');
      const messages = compactMessages(context.messages);
      const inputChars = JSON.stringify(messages).length;
      state.inputChars += inputChars;
      if (inputChars > MAX_REQUEST_CHARS) fail('Ask per-request input limit reached');
      if (state.inputChars > MAX_INPUT_CHARS) fail('Ask cumulative input limit reached');
      const response = await request('modelDecision', { messages });
      if (response.kind !== 'decision' || !object(response.action)) fail('Invalid model decision response');
      const action = response.action;
      if (action.kind === 'tool') {
        if (!allowed.has(action.toolName) || !object(action.arguments)) fail('Invalid tool decision');
        const message = piMessage([{ type: 'toolCall', id: `${state.runID}:tool:${state.turns}`, name: action.toolName, arguments: action.arguments }], 'toolUse');
        emitPi(stream, message);
      } else if (action.kind === 'final') {
        let body = '';
        const final = await request('modelFinal', { messages }, (chunk) => {
          state.outputChars += chunk.length;
          if (state.outputChars > MAX_OUTPUT_CHARS) fail('Ask output limit reached');
          body += chunk;
          write('text', null, { text: chunk });
        });
        if (final.kind !== 'modelDone' || !body.trim()) fail('Empty final answer');
        state.finalText = body;
        emitPi(stream, piMessage([{ type: 'text', text: body }], 'stop'));
      } else fail('Unknown model decision');
    } catch (error) { rejectPi(stream, error); }
  })();
  return stream;
}
async function run(start) {
  const messages = start.messages;
  if (!Array.isArray(messages) || !messages.length || messages.some((m) => !object(m) || !['system','user','assistant'].includes(m.role) || typeof m.content !== 'string')) fail('Invalid start messages');
  const tools = Object.keys(schemas).map((name) => ({
    name, label: name, description: descriptions[name], parameters: schemas[name], executionMode: 'sequential',
    execute: async (_id, args, signal) => {
      if (signal?.aborted) throw signal.reason;
      const reply = await request('tool', { toolName: name, argumentsJSON: JSON.stringify(args) });
      if (reply.kind !== 'toolResult' || typeof reply.resultJSON !== 'string') throw new Error('Invalid tool result');
      if (reply.resultJSON.length > MAX_TOOL_CHARS) throw new Error('Tool result exceeds limit');
      state.evidenceChars += reply.resultJSON.length;
      if (state.evidenceChars > MAX_EVIDENCE_CHARS) throw new Error('Ask evidence limit reached');
      JSON.parse(reply.resultJSON);
      return { content: [{ type: 'text', text: reply.resultJSON }] };
    },
  }));
  const prompt = [{ role: 'system', content: 'Investigate only selected sources using the declared tools. Search and read before asserting transcript facts. Cite actual passage handles returned by tools using [E1], [E2], etc. Summaries orient; transcripts substantiate. State limits and uncertainty. Never claim unexamined sources were checked.', timestamp: Date.now() }, ...messages.map((m) => m.role === 'assistant' ? piMessage([{ type: 'text', text: m.content }], 'stop') : { ...m, timestamp: Date.now() })];
  const model = { id: 'configured', name: 'Configured MacParakeet model', api: 'openai-completions', provider: 'macparakeet', baseUrl: 'local-bridge', reasoning: false, input: ['text'], cost, contextWindow: 65536, maxTokens: 4096 };
  const timeout = setTimeout(() => state.abort.abort(new Error('Ask deadline exceeded')), DEADLINE_MS);
  try {
    const emitted = await runAgentLoop(prompt, { messages: [], tools }, { model, convertToLlm: (m) => m, toolExecution: 'sequential' }, async (event) => {
      if (event.type === 'tool_execution_start') {
        const label = { list_sources: 'Checking selected recordings', search: 'Searching transcripts', read: 'Reading a passage', get_summary: 'Checking saved summaries' }[event.toolName];
        if (label) write('activity', null, { text: label });
      }
    }, state.abort.signal, streamFn);
    const last = emitted.findLast((m) => m.role === 'assistant');
    if (state.abort.signal.aborted) throw state.abort.signal.reason;
    if (last?.stopReason !== 'stop' || !state.finalText) throw new Error(last?.errorMessage || 'Agent stopped without an answer');
    write('done', start.requestID, { answerSHA256: createHash('sha256').update(state.finalText).digest('hex'), turns: state.turns });
    state.completed = true;
    lines.close();
  } finally { clearTimeout(timeout); }
}
const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
lines.on('line', (line) => {
  try {
    if (Buffer.byteLength(line) > MAX_FRAME) fail('Incoming frame exceeds limit');
    const frame = JSON.parse(line);
    if (!state.started) {
      if (!object(frame) || frame.v !== VERSION || frame.kind !== 'start' || typeof frame.runID !== 'string' || typeof frame.scopeID !== 'string' || typeof frame.requestID !== 'string') throw new Error('Invalid start frame');
      state.started = true; state.runID = frame.runID; state.scopeID = frame.scopeID;
      void run(frame).catch((error) => { write('error', frame.requestID, { message: error instanceof Error ? error.message : String(error) }); process.exitCode = 1; lines.close(); });
    } else validateReply(frame);
  } catch (error) {
    if (state.started) write('error', null, { message: error instanceof Error ? error.message : String(error) });
    process.exitCode = 1; lines.close();
  }
});
lines.on('close', () => { process.stdin.destroy(); if (state.completed) return; state.abort.abort(new Error('Host pipe closed')); for (const p of state.pending.values()) p.reject(state.abort.signal.reason); });
