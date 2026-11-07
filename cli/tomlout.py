"""A tiny TOML writer for journey files: scalars, arrays, inline tables, tables and arrays of tables.

TOML has no null, so callers pass JSON-shaped values without `None`; `dumps` raises if it meets one.
"""
import math
import re

BARE_KEY = re.compile(r'^[A-Za-z0-9_-]+$')


def key(name):
    name = str(name)
    return name if BARE_KEY.match(name) else string(name)


def string(text):
    escaped = []
    for character in text:
        code = ord(character)
        if character == '"':
            escaped.append('\\"')
        elif character == '\\':
            escaped.append('\\\\')
        elif character == '\n':
            escaped.append('\\n')
        elif character == '\t':
            escaped.append('\\t')
        elif character == '\r':
            escaped.append('\\r')
        elif code < 0x20 or code == 0x7f:
            escaped.append(f'\\u{code:04x}')
        else:
            escaped.append(character)
    return '"' + ''.join(escaped) + '"'


def value(item):
    if item is None:
        raise ValueError('TOML cannot represent null')
    if isinstance(item, bool):
        return 'true' if item else 'false'
    if isinstance(item, int):
        return str(item)
    if isinstance(item, float):
        if math.isnan(item):
            return 'nan'
        if math.isinf(item):
            return 'inf' if item > 0 else '-inf'
        text = repr(item)
        return text if any(c in text for c in '.en') else text + '.0'
    if isinstance(item, str):
        return string(item)
    if isinstance(item, (list, tuple)):
        return '[' + ', '.join(value(element) for element in item) + ']'
    if isinstance(item, dict):
        if not item:
            return '{}'
        return '{ ' + ', '.join(f'{key(k)} = {value(v)}' for k, v in item.items()) + ' }'
    raise ValueError(f'TOML cannot represent {type(item).__name__}')


def contains_null(item):
    if item is None:
        return True
    if isinstance(item, dict):
        return any(contains_null(v) for v in item.values())
    if isinstance(item, (list, tuple)):
        return any(contains_null(v) for v in item)
    return False


def dumps(document, header=None):
    """Top-level scalars and arrays first, then tables and arrays of tables in document order.

    A dict value becomes a `[table]`, a non-empty list of dicts an `[[array of tables]]`; dicts nested
    inside those are written inline.
    """
    lines = [f'# {line}' if line else '#' for line in (header or '').splitlines()]
    sections = []
    for name, item in document.items():
        if isinstance(item, dict):
            sections.append(('table', name, item))
        elif isinstance(item, list) and item and all(isinstance(element, dict) for element in item):
            sections.append(('array', name, item))
        else:
            lines.append(f'{key(name)} = {value(item)}')
    for kind, name, item in sections:
        for table in (item if kind == 'array' else [item]):
            lines += ['', f'[[{key(name)}]]' if kind == 'array' else f'[{key(name)}]']
            lines += [f'{key(k)} = {value(v)}' for k, v in table.items()]
    return '\n'.join(lines).lstrip('\n') + '\n'
