import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const helper = process.env.MACPARAKEET_ASK_TEST_HELPER
  ? resolve(process.env.MACPARAKEET_ASK_TEST_HELPER)
  : resolve(dirname(fileURLToPath(import.meta.url)), '../dist/ask-helper.cjs');
const runID = '00000000-0000-0000-0000-000000000001';
const scopeID = '00000000-0000-0000-0000-000000000002';
const startID = `${runID}:start`;
const base = { v: 1, runID, scopeID };

async function launch(handler, messages = [{ role: 'user', content: 'How did the plan change?' }]) {
  const child = spawn(process.env.ASK_TEST_NODE || process.execPath, [helper], { stdio: ['pipe', 'pipe', 'pipe'], env: { PATH: '/usr/bin:/bin', HOME: '/var/empty' } });
  const frames = [];
  let stderr = '';
  child.stderr.on('data', (data) => { stderr += data; });
  const send = (frame) => child.stdin.write(JSON.stringify({ ...base, ...frame }) + '\n');
  const exited = new Promise((resolveExit, reject) => {
    child.once('error', reject);
    child.once('exit', (code, signal) => resolveExit({ code, signal }));
  });
  const reading = (async () => {
    for await (const line of createInterface({ input: child.stdout })) {
      const frame = JSON.parse(line);
      frames.push(frame);
      await handler(frame, send, child);
    }
  })();
  send({ kind: 'start', requestID: startID, messages, budget: { initialBytes: 16_000, requestBytes: 56_000 } });
  return { child, send, frames, exited, reading, stderr: () => stderr };
}

test('published Pi executes tool continuation and streams final text', async () => {
  let decisions = 0;
  let tools = 0;
  const run = await launch((frame, send) => {
    if (frame.kind === 'modelDecision') {
      decisions++;
      const action = decisions === 1
        ? { kind: 'tool', toolName: 'search', arguments: { query: 'launch date', limit: 3 } }
        : decisions === 2
          ? { kind: 'tool', toolName: 'read', arguments: { sourceID: 'meeting-1', start: 0, limit: 5 } }
          : { kind: 'final' };
      send({ kind: 'decision', requestID: frame.requestID, action });
    } else if (frame.kind === 'tool') {
      tools++;
      assert.deepEqual(JSON.parse(frame.argumentsJSON), tools === 1 ? { query: 'launch date', limit: 3 } : { sourceID: 'meeting-1', start: 0, limit: 5 });
      send({ kind: 'toolResult', requestID: frame.requestID, resultJSON: JSON.stringify({ passages: [{ sourceID: 'meeting-1', text: 'The launch moved to October.' }] }) });
    } else if (frame.kind === 'modelFinal') {
      send({ kind: 'modelChunk', requestID: frame.requestID, text: 'The launch moved to October ' });
      send({ kind: 'modelChunk', requestID: frame.requestID, text: '[meeting-1].' });
      send({ kind: 'modelDone', requestID: frame.requestID });
    }
  });
  const result = await run.exited;
  await run.reading;
  assert.equal(result.code, 0, run.stderr());
  assert.equal(decisions, 3);
  assert.equal(tools, 2);
  assert.equal(run.frames.filter((f) => f.kind === 'text').map((f) => f.text).join(''), 'The launch moved to October [meeting-1].');
  assert.equal(run.frames.at(-1).kind, 'done');
  assert.equal(run.frames.at(-1).answerSHA256, createHash('sha256').update('The launch moved to October [meeting-1].').digest('hex'));
});

test('wrong run ID fails closed', async () => {
  const run = await launch((frame, send) => {
    if (frame.kind === 'modelDecision') send({ kind: 'decision', runID: 'wrong', requestID: frame.requestID, action: { kind: 'final' } });
  });
  const result = await run.exited;
  await run.reading;
  assert.notEqual(result.code, 0);
  assert.equal(run.frames.some((f) => f.kind === 'done'), false);
  assert.match(run.frames.find((f) => f.kind === 'error')?.message ?? '', /identity/i);
});

test('unknown tool decision fails without tool execution', async () => {
  const run = await launch((frame, send) => {
    if (frame.kind === 'modelDecision') send({ kind: 'decision', requestID: frame.requestID, action: { kind: 'tool', toolName: 'shell', arguments: { command: 'pwd' } } });
  });
  const result = await run.exited;
  await run.reading;
  assert.notEqual(result.code, 0);
  assert.equal(run.frames.some((f) => f.kind === 'tool'), false);
});

test('host pipe closure cancels pending model work', async () => {
  const run = await launch((frame, _send, child) => {
    if (frame.kind === 'modelDecision') child.stdin.end();
  });
  const result = await run.exited;
  await run.reading;
  assert.notEqual(result.code, 0);
  assert.equal(run.frames.some((f) => f.kind === 'done'), false);
});

test('max turn budget stops a tool loop', async () => {
  let decisions = 0;
  const run = await launch((frame, send) => {
    if (frame.kind === 'modelDecision') {
      decisions++;
      send({ kind: 'decision', requestID: frame.requestID, action: { kind: 'tool', toolName: 'list_sources', arguments: {} } });
    } else if (frame.kind === 'tool') {
      send({ kind: 'toolResult', requestID: frame.requestID, resultJSON: '{"sources":[]}' });
    }
  });
  const result = await run.exited;
  await run.reading;
  assert.notEqual(result.code, 0);
  assert.equal(decisions, 12);
  assert.equal(run.frames.some((f) => f.kind === 'done'), false);
  assert.match(run.frames.findLast((f) => f.kind === 'error')?.message ?? '', /turn limit/i);
});

test('wrong request ID fails closed', async () => {
  const run = await launch((frame, send) => {
    if (frame.kind === 'modelDecision') send({ kind: 'decision', requestID: 'unrelated', action: { kind: 'final' } });
  });
  const result = await run.exited;
  await run.reading;
  assert.notEqual(result.code, 0);
  assert.equal(run.frames.some((f) => f.kind === 'done'), false);
});

test('oversized host frame fails before model response', async () => {
  const run = await launch((frame, send) => {
    if (frame.kind === 'modelDecision') send({ kind: 'decision', requestID: frame.requestID, padding: 'x'.repeat(70_000), action: { kind: 'final' } });
  });
  const result = await run.exited;
  await run.reading;
  assert.notEqual(result.code, 0);
  assert.equal(run.frames.some((f) => f.kind === 'modelFinal'), false);
});

test('host pipe closure cancels pending tool work', async () => {
  const run = await launch((frame, send, child) => {
    if (frame.kind === 'modelDecision') send({ kind: 'decision', requestID: frame.requestID, action: { kind: 'tool', toolName: 'list_sources', arguments: {} } });
    else if (frame.kind === 'tool') child.stdin.end();
  });
  const result = await run.exited;
  await run.reading;
  assert.notEqual(result.code, 0);
  assert.equal(run.frames.some((f) => f.kind === 'done'), false);
});

test('saved assistant history continues through the Pi transcript', async () => {
  const run = await launch((frame, send) => {
    if (frame.kind === 'modelDecision') {
      assert.equal(frame.messages.some((m) => m.role === 'assistant' && m.content === 'The earlier date was June.'), true);
      send({ kind: 'decision', requestID: frame.requestID, action: { kind: 'final' } });
    } else if (frame.kind === 'modelFinal') {
      send({ kind: 'modelChunk', requestID: frame.requestID, text: 'It changed to July.' });
      send({ kind: 'modelDone', requestID: frame.requestID });
    }
  }, [
    { role: 'user', content: 'What was the original date?' },
    { role: 'assistant', content: 'The earlier date was June.' },
    { role: 'user', content: 'What happened next?' },
  ]);
  const result = await run.exited;
  await run.reading;
  assert.equal(result.code, 0, run.stderr());
  assert.equal(run.frames.at(-1).kind, 'done');
});

test('bundle notice manifest names only bundled dependencies', () => {
  const manifest = JSON.parse(readFileSync(resolve(dirname(helper), 'Legal/dependencies.json'), 'utf8'));
  const packages = new Map(manifest.packages.map((entry) => [entry.name, entry]));
  assert.equal(packages.get('@earendil-works/pi-agent-core')?.version, '0.87.1');
  assert.equal(packages.get('@earendil-works/pi-ai')?.version, '0.87.1');
  assert.equal(packages.get('@earendil-works/pi-agent-core')?.license, 'MIT');
  assert.equal(packages.has('@earendil-works/pi-coding-agent'), false);
  for (const entry of manifest.packages) assert.ok(entry.files.length > 0, entry.name);
});


test('two permitted summaries fit and tool actions replay the decision schema', async () => {
  let decisions = 0;
  const summaries = ['a'.repeat(16_000), 'b'.repeat(16_000)];
  const run = await launch((frame, send) => {
    if (frame.kind === 'modelDecision') {
      decisions++;
      if (decisions === 3) {
        for (const text of summaries) assert.ok(frame.messages.some((m) => m.content.includes(text)));
        const actions = frame.messages.filter((m) => m.role === 'assistant').map((m) => JSON.parse(m.content));
        assert.deepEqual(actions, [0, 1].map((i) => ({ kind: 'tool', toolName: 'get_summary', query: '', sourceID: `source-${i}`, start: 0, limit: 0 })));
      }
      send({ kind: 'decision', requestID: frame.requestID, action: decisions <= 2
        ? { kind: 'tool', toolName: 'get_summary', arguments: { sourceID: `source-${decisions - 1}` } }
        : { kind: 'final' } });
    } else if (frame.kind === 'tool') {
      send({ kind: 'toolResult', requestID: frame.requestID, resultJSON: JSON.stringify({ summary: summaries[decisions - 1] }) });
    } else if (frame.kind === 'modelFinal') {
      send({ kind: 'modelChunk', requestID: frame.requestID, text: 'These summaries orient further transcript investigation.' });
      send({ kind: 'modelDone', requestID: frame.requestID });
    }
  });
  const result = await run.exited;
  await run.reading;
  assert.equal(result.code, 0, JSON.stringify(run.frames.at(-1)));
  assert.equal(decisions, 3);
  assert.equal(run.frames.at(-1).kind, 'done');
});

test('oversized UTF8 initial context fails before requesting a model', async () => {
  const run = await launch((frame, _send, child) => { if (frame.kind === 'modelDecision') child.stdin.end(); }, [{ role: 'user', content: '界'.repeat(6_000) }]);
  const result = await run.exited;
  await run.reading;
  assert.notEqual(result.code, 0);
  assert.equal(run.frames.some((frame) => frame.kind === 'modelDecision'), false);
  assert.equal(run.frames.findLast((frame) => frame.kind === 'error')?.code, 'budgetExceeded');
});

test('context exhaustion is categorized without a partial final answer', async () => {
  const run = await launch((frame, send) => {
    if (frame.kind === 'modelDecision') {
      send({ kind: 'decision', requestID: frame.requestID, action: { kind: 'tool', toolName: 'get_summary', arguments: { sourceID: 'source' } } });
    } else if (frame.kind === 'tool') {
      send({ kind: 'toolResult', requestID: frame.requestID, resultJSON: JSON.stringify({ summary: 'x'.repeat(16_000) }) });
    }
  });
  const result = await run.exited;
  await run.reading;
  assert.notEqual(result.code, 0);
  assert.equal(run.frames.some((frame) => frame.kind === 'modelFinal'), false);
  assert.equal(run.frames.findLast((frame) => frame.kind === 'error')?.code, 'budgetExceeded');
});


test('accumulated Unicode evidence uses UTF8 bytes rather than character count', async () => {
  let decisions = 0;
  const run = await launch((frame, send) => {
    if (frame.kind === 'modelDecision') {
      decisions++;
      send({ kind: 'decision', requestID: frame.requestID, action: { kind: 'tool', toolName: 'get_summary', arguments: { sourceID: 'source' } } });
    } else if (frame.kind === 'tool') {
      send({ kind: 'toolResult', requestID: frame.requestID, resultJSON: JSON.stringify({ summary: '界'.repeat(9_000) }) });
    }
  }, [{ role: 'user', content: 'x'.repeat(4_000) }]);
  const result = await run.exited;
  await run.reading;
  assert.notEqual(result.code, 0);
  assert.equal(decisions, 2);
  assert.equal(run.frames.findLast((frame) => frame.kind === 'error')?.code, 'budgetExceeded');
});
