"""AI mode: turn a plain-language request into settings for the editing engine.

The engine still makes every cut. The AI only fills in the knobs a person would set by hand (main
camera, pace, forced cameras, drops and breakdowns, no-clip ranges, clip lengths and filters), so the
cuts keep the same style. Providers: the Claude Code or Codex command-line tools (signed in with your
subscription) or an OpenRouter API key. Stdlib only. Mirrors AIGuide.swift in the Mac app.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import urllib.error
import urllib.request

from looks import STYLES

PROVIDERS = ('claude', 'codex', 'openrouter')
DEFAULT_OPENROUTER_MODEL = 'openrouter/auto'
TIMEOUT = 300

SYSTEM_PROMPT = """You are the assistant editor inside Multicam Studio, an app that cuts DJ sets filmed with several cameras.
The app's editing engine already makes beat-synced cuts, faster in drops and slower in breakdowns. You never
make cuts yourself: you steer the engine by choosing settings, exactly as the DJ would by hand.

You get a JSON summary of the set (audio parts with their duration, tempo, drops and sections; the cameras,
with their shape; the current settings and markers) and a request from the DJ. Return ONLY a JSON object:
- "summary": one or two sentences telling the DJ what you changed and why.
- "main_camera": a camera id to favour, or null to keep it.
- "main_share": share of screen time for the main camera, 0.2 to 0.9, or null.
- "pace": cutting speed, 0.4 (much slower) to 2.5 (much faster), 1 = normal, or null.
- "clip_lengths": social clip lengths in seconds (e.g. [15, 30]), or null.
- "clip_count": social clips per length (0 = as many as fit), or null.
- "clip_mode": "best" (most energetic moments) or "sequence" (whole set in order), or null.
- "clip_filters": "auto", "off" or one look (none, warm, cool, mono, vintage, vivid, noir, silver, sepia, super8, faded), or null.
- "parts": a list with one entry per audio part you change: {"part": its number, "force_cameras": [{"start", "end", "camera"}],
  "no_clips": [[start, end]], "drops": [[start, end]], "breakdowns": [[start, end]]}. Times are seconds within that part.
  Forced cameras override the engine in that range; no_clips keeps social clips out of a range; drops and
  breakdowns replace the detected sections for that part, so only add them when the DJ asks.
Change only what the request needs; use null or empty lists for the rest. Use camera ids exactly as given.
Keep forced ranges to what was asked for: the engine's own choices are usually best."""

_RANGES = {'type': 'array', 'items': {'type': 'array', 'items': {'type': 'number'}}}
SCHEMA = {
    'type': 'object', 'additionalProperties': False,
    'required': ['summary', 'main_camera', 'main_share', 'pace', 'clip_lengths', 'clip_count', 'clip_mode', 'clip_filters', 'parts'],
    'properties': {
        'summary': {'type': 'string'},
        'main_camera': {'type': ['string', 'null']},
        'main_share': {'type': ['number', 'null']},
        'pace': {'type': ['number', 'null']},
        'clip_lengths': {'type': ['array', 'null'], 'items': {'type': 'number'}},
        'clip_count': {'type': ['integer', 'null']},
        'clip_mode': {'type': ['string', 'null'], 'enum': ['best', 'sequence', None]},
        'clip_filters': {'type': ['string', 'null']},
        'parts': {'type': 'array', 'items': {
            'type': 'object', 'additionalProperties': False,
            'required': ['part', 'force_cameras', 'no_clips', 'drops', 'breakdowns'],
            'properties': {
                'part': {'type': 'integer'},
                'force_cameras': {'type': 'array', 'items': {
                    'type': 'object', 'additionalProperties': False, 'required': ['start', 'end', 'camera'],
                    'properties': {'start': {'type': 'number'}, 'end': {'type': 'number'}, 'camera': {'type': 'string'}}}},
                'no_clips': _RANGES, 'drops': _RANGES, 'breakdowns': _RANGES}}},
    },
}


class AIError(RuntimeError):
    pass


def find_cli(name):
    """The Claude Code / Codex tool, also where installers put it outside the server's PATH."""
    found = shutil.which(name)
    if found:
        return found
    home = Path.home()
    for folder in (home / '.local/bin', home / '.npm-global/bin', home / '.bun/bin', home / '.claude/local',
                   Path('/opt/homebrew/bin'), Path('/usr/local/bin')):
        candidate = folder / name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def cli_environment():
    """The environment for the Claude Code / Codex tools, without the settings a Claude Code session
    passes to its children (they point the tool at that session instead of your own sign-in)."""
    env = dict(os.environ)
    inside_session = 'CLAUDECODE' in env
    for name in list(env):
        if (name.startswith(('CLAUDE_CODE_', 'CLAUDE_AGENT_SDK')) or name in ('CLAUDECODE', 'CLAUDE_PID', 'CLAUDE_EFFORT', 'AI_AGENT')
                or (inside_session and name == 'ANTHROPIC_BASE_URL')):
            env.pop(name)
    return env


def available(openrouter_key=''):
    return {'claude': bool(find_cli('claude')), 'codex': bool(find_cli('codex')), 'openrouter': bool(openrouter_key)}


def request_text(prompt, context):
    return f"Set summary (JSON):\n{json.dumps(context, separators=(',', ':'))}\n\nRequest from the DJ:\n{prompt.strip()}"


def ask(provider, prompt, context, key='', model='', timeout=TIMEOUT):
    """Ask the provider and return its validated guidance."""
    if provider not in PROVIDERS:
        raise AIError('Choose Claude Code, Codex or OpenRouter.')
    if not prompt.strip():
        raise AIError('Tell the AI what you want first.')
    text = request_text(prompt, context)
    if provider == 'openrouter':
        raw = _openrouter(text, key, model or DEFAULT_OPENROUTER_MODEL, timeout)
    else:
        raw = _cli(provider, text, timeout, model)
    return validate(parse(raw), context)


def _cli(provider, text, timeout, model=''):
    tool = find_cli(provider)
    if not tool:
        name = 'Claude Code' if provider == 'claude' else 'Codex'
        raise AIError(f'{name} isn’t installed on this machine. Install it and sign in, or use OpenRouter.')
    with tempfile.TemporaryDirectory(prefix='multicam-ai-') as work:
        # An empty folder, no tools and no saved session: the AI only reads the summary and answers.
        if provider == 'claude':
            cmd = [tool, '-p', '--output-format', 'json', '--tools', '', '--no-session-persistence',
                   '--json-schema', json.dumps(SCHEMA), '--system-prompt', SYSTEM_PROMPT]
            cmd += ['--model', model] if model else []
            cmd.append(text)
        else:
            schema = Path(work) / 'schema.json'
            schema.write_text(json.dumps(SCHEMA), encoding='utf-8')
            answer = Path(work) / 'answer.json'
            cmd = [tool, 'exec', '--skip-git-repo-check', '--ephemeral', '-s', 'read-only',
                   '--output-schema', str(schema), '-o', str(answer)]
            cmd += ['-m', model] if model else []
            cmd.append(SYSTEM_PROMPT + '\n\n' + text)
        try:
            result = subprocess.run(cmd, cwd=work, capture_output=True, text=True, encoding='utf-8',
                                    errors='replace', timeout=timeout, stdin=subprocess.DEVNULL, env=cli_environment())
        except subprocess.TimeoutExpired:
            raise AIError('The AI took too long to answer. Try again or use a shorter request.')
        if provider == 'claude':
            try:
                envelope = json.loads(result.stdout)
            except ValueError:
                raise AIError(_tail(result.stderr or result.stdout) or 'Claude Code gave no answer.')
            if envelope.get('is_error'):
                message = str(envelope.get('result') or 'Claude Code returned an error.')
                if 'authenticat' in message.lower() or '401' in message:
                    message = ('Claude Code’s own sign-in on this machine has expired (it is separate from the Claude app). '
                               'Open Terminal, run "claude auth login", then try again.')
                raise AIError(message)
            if isinstance(envelope.get('structured_output'), dict):
                return json.dumps(envelope['structured_output'])
            return str(envelope.get('result') or '')
        if result.returncode or not answer.exists():
            message = _tail(result.stderr or result.stdout) or 'Codex gave no answer.'
            if 'login' in message.lower() or 'auth' in message.lower():
                message += ' Open Terminal and run "codex login" to sign in.'
            elif 'model' in message.lower():
                message += ' Type a model your Codex account supports in the Model box, or change it in ~/.codex/config.toml.'
            raise AIError(message)
        return answer.read_text(encoding='utf-8')


def _openrouter(text, key, model, timeout):
    if not key:
        raise AIError('Add your OpenRouter API key first.')
    body = {'model': model, 'messages': [{'role': 'system', 'content': SYSTEM_PROMPT}, {'role': 'user', 'content': text}],
            'response_format': {'type': 'json_object'}}
    request = urllib.request.Request('https://openrouter.ai/api/v1/chat/completions', data=json.dumps(body).encode(),
                                     headers={'Authorization': f'Bearer {key}', 'Content-Type': 'application/json',
                                              'X-Title': 'Multicam Studio'})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            data = json.loads(response.read().decode('utf-8'))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode('utf-8', 'replace')
        try:
            detail = json.loads(detail)['error']['message']
        except (ValueError, KeyError, TypeError):
            pass
        raise AIError(f'OpenRouter: {detail or exc.reason}')
    except (urllib.error.URLError, TimeoutError) as exc:
        raise AIError(f'Couldn’t reach OpenRouter: {getattr(exc, "reason", exc)}')
    try:
        return data['choices'][0]['message']['content']
    except (KeyError, IndexError, TypeError):
        raise AIError('OpenRouter returned no answer.')


def _tail(text):
    messages = re.findall(r'"message"\s*:\s*"([^"]+)"', str(text))
    if messages:
        return messages[-1][:500]
    lines = [line for line in str(text).strip().splitlines() if line.strip()]
    return ' '.join(lines[-3:])[-500:]


def parse(text):
    """The first JSON object in the answer (models sometimes wrap it in prose or a code fence)."""
    text = str(text).strip()
    try:
        value = json.loads(text)
        if isinstance(value, dict):
            return value
    except ValueError:
        pass
    start = text.find('{')
    while start != -1:
        depth = 0
        for i in range(start, len(text)):
            if text[i] == '{':
                depth += 1
            elif text[i] == '}':
                depth -= 1
                if depth == 0:
                    try:
                        value = json.loads(text[start:i + 1])
                        if isinstance(value, dict):
                            return value
                    except ValueError:
                        break
        start = text.find('{', start + 1)
    raise AIError('The AI’s answer wasn’t in the expected format. Try again.')


def _number(value, low, high):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value != value:
        return None
    return min(high, max(low, float(value)))


def _ranges(values, duration):
    out = []
    for pair in values or []:
        if not isinstance(pair, (list, tuple)) or len(pair) != 2:
            continue
        a, b = _number(pair[0], 0, duration), _number(pair[1], 0, duration)
        if a is not None and b is not None and b - a >= 0.5:
            out.append([round(a, 3), round(b, 3)])
    return sorted(out)[:200]


def validate(raw, context):
    """Keep only well-formed values inside the limits the engine accepts."""
    if not isinstance(raw, dict):
        raise AIError('The AI’s answer wasn’t in the expected format. Try again.')
    cameras = {c['id'] for c in context.get('cameras', [])}
    out = {'summary': str(raw.get('summary') or 'Done.').strip()[:800]}
    if raw.get('main_camera') in cameras:
        out['main_camera'] = raw['main_camera']
    if (share := _number(raw.get('main_share'), 0.2, 0.9)) is not None:
        out['main_share'] = round(share, 2)
    if (pace := _number(raw.get('pace'), 0.4, 2.5)) is not None:
        out['pace'] = round(pace, 2)
    if isinstance(raw.get('clip_lengths'), list):
        lengths = sorted({round(n) for n in (_number(v, 3, 180) for v in raw['clip_lengths']) if n is not None})[:6]
        if lengths:
            out['clip_lengths'] = lengths
    if (count := _number(raw.get('clip_count'), 0, 50)) is not None:
        out['clip_count'] = int(count)
    if raw.get('clip_mode') in ('best', 'sequence'):
        out['clip_mode'] = raw['clip_mode']
    if raw.get('clip_filters') in ('auto', 'off', *STYLES):
        out['clip_filters'] = raw['clip_filters']
    parts = context.get('parts', [])
    changes = {}
    for item in raw.get('parts') or []:
        if not isinstance(item, dict) or isinstance(item.get('part'), bool) or not isinstance(item.get('part'), int):
            continue
        index = item['part']
        if not 1 <= index <= len(parts):
            continue
        duration = float(parts[index - 1].get('duration') or 24 * 3600)
        entry = changes.setdefault(index, {'part': index, 'force_cameras': [], 'no_clips': [], 'drops': [], 'breakdowns': []})
        for force in item.get('force_cameras') or []:
            if isinstance(force, dict) and force.get('camera') in cameras:
                span = _ranges([[force.get('start'), force.get('end')]], duration)
                if span:
                    entry['force_cameras'].append({'start': span[0][0], 'end': span[0][1], 'camera': force['camera']})
        for key in ('no_clips', 'drops', 'breakdowns'):
            entry[key] += _ranges(item.get(key), duration)
    out['parts'] = [p for p in changes.values() if any(p[k] for k in ('force_cameras', 'no_clips', 'drops', 'breakdowns'))]
    return out


def describe(guidance):
    """Short lines for the UI listing what will change."""
    lines = []
    if 'main_camera' in guidance: lines.append(f"Main camera: {guidance['main_camera']}")
    if 'main_share' in guidance: lines.append(f"Main camera screen time: {round(guidance['main_share'] * 100)}%")
    if 'pace' in guidance: lines.append(f"Pace: {guidance['pace']}×")
    if 'clip_lengths' in guidance: lines.append('Clip lengths: ' + ', '.join(f'{n} s' for n in guidance['clip_lengths']))
    if 'clip_count' in guidance: lines.append(f"Clips per length: {guidance['clip_count'] or 'as many as fit'}")
    if 'clip_mode' in guidance: lines.append('Clips: ' + ('best moments' if guidance['clip_mode'] == 'best' else 'whole set in order'))
    if 'clip_filters' in guidance: lines.append(f"Filters: {guidance['clip_filters']}")
    for part in guidance.get('parts', []):
        bits = [f"{len(part[k])} {label}" for k, label in (('force_cameras', 'forced camera range(s)'), ('no_clips', 'no-clip range(s)'),
                                                            ('drops', 'drop(s)'), ('breakdowns', 'breakdown(s)')) if part[k]]
        lines.append(f"Part {part['part']}: " + ', '.join(bits))
    return lines
