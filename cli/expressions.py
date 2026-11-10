"""Safe check expressions over a published state tree (journey `expect` and `[checks]`).

The grammar is a small subset of Python, parsed with `ast` and evaluated by walking a whitelist of
nodes. Nothing is ever passed to `eval`. Names and attributes read keys of JSON objects; a missing
key, or any read from a missing value, gives `None`, so `not editor.title` holds when the editor is
closed. Allowed: attribute access, indexing (and slices), comparisons, `and`/`or`/`not`, arithmetic,
generator expressions, and calls to len, any, all, sum, min, max, sorted and set.
"""
import ast

MAX_LENGTH = 2000          # characters of source
MAX_DEPTH = 60             # nested nodes
MAX_ITERATIONS = 1_000_000  # generator steps per evaluation
MAX_SEQUENCE = 100_000     # elements in a string or list built by `*` or `+`

FUNCTIONS = {
    'len': len, 'any': any, 'all': all, 'sum': sum, 'min': min, 'max': max, 'sorted': sorted, 'set': set,
}
BOOL_OPERATORS = {ast.And, ast.Or}
UNARY_OPERATORS = {ast.Not, ast.USub, ast.UAdd}
BINARY_OPERATORS = {ast.Add, ast.Sub, ast.Mult, ast.Div, ast.FloorDiv, ast.Mod}
COMPARISONS = {ast.Eq, ast.NotEq, ast.Lt, ast.LtE, ast.Gt, ast.GtE, ast.In, ast.NotIn, ast.Is, ast.IsNot}
ORDERING = (ast.Lt, ast.LtE, ast.Gt, ast.GtE)


class ExpressionError(ValueError):
    """A check that is not allowed, does not parse, or cannot be evaluated against this state."""


def compile_expression(source):
    """Parse and validate once; returns a tree for `evaluate`. Raises ExpressionError."""
    if not isinstance(source, str) or not source.strip():
        raise ExpressionError('empty expression')
    if len(source) > MAX_LENGTH:
        raise ExpressionError(f'expression longer than {MAX_LENGTH} characters')
    try:
        tree = ast.parse(source.strip(), mode='eval')
    except SyntaxError as error:
        raise ExpressionError(f'syntax error: {error.msg}') from None
    except (ValueError, RecursionError, MemoryError):
        raise ExpressionError('expression could not be parsed') from None
    _validate(tree.body, 0, set())
    return tree.body


def _validate(node, depth, bound):
    if depth > MAX_DEPTH:
        raise ExpressionError('expression is nested too deeply')
    kind = type(node)
    nested = lambda child, names=bound: _validate(child, depth + 1, names)
    if kind is ast.Constant:
        if not (node.value is None or isinstance(node.value, (bool, int, float, str))):
            raise ExpressionError(f'constant {node.value!r} is not allowed')
    elif kind is ast.Name:
        if not isinstance(node.ctx, ast.Load) or node.id.startswith('__'):
            raise ExpressionError(f'name {node.id!r} is not allowed')
    elif kind is ast.Attribute:
        if node.attr.startswith('__'):
            raise ExpressionError(f'attribute {node.attr!r} is not allowed')
        nested(node.value)
    elif kind is ast.Subscript:
        nested(node.value)
        nested(node.slice)
    elif kind is ast.Slice:
        for part in (node.lower, node.upper, node.step):
            if part is not None:
                nested(part)
    elif kind is ast.BoolOp:
        if type(node.op) not in BOOL_OPERATORS:
            raise ExpressionError('operator is not allowed')
        for value in node.values:
            nested(value)
    elif kind is ast.UnaryOp:
        if type(node.op) not in UNARY_OPERATORS:
            raise ExpressionError(f'operator {type(node.op).__name__} is not allowed')
        nested(node.operand)
    elif kind is ast.BinOp:
        if type(node.op) not in BINARY_OPERATORS:
            raise ExpressionError(f'operator {type(node.op).__name__} is not allowed')
        nested(node.left)
        nested(node.right)
    elif kind is ast.Compare:
        if any(type(op) not in COMPARISONS for op in node.ops):
            raise ExpressionError('comparison is not allowed')
        nested(node.left)
        for comparator in node.comparators:
            nested(comparator)
    elif kind is ast.Call:
        if type(node.func) is not ast.Name or node.func.id not in FUNCTIONS:
            raise ExpressionError('only len, any, all, sum, min, max, sorted and set can be called')
        if node.keywords or any(type(argument) is ast.Starred for argument in node.args):
            raise ExpressionError('calls take positional arguments only')
        for argument in node.args:
            nested(argument)
    elif kind is ast.GeneratorExp:
        names = set(bound)
        for generator in node.generators:
            if generator.is_async:
                raise ExpressionError('async generators are not allowed')
            nested(generator.iter, names)
            names |= _targets(generator.target)
            for condition in generator.ifs:
                nested(condition, names)
        nested(node.elt, names)
    else:
        raise ExpressionError(f'{kind.__name__} is not allowed in checks')


def _targets(target):
    if type(target) is ast.Name and not target.id.startswith('__'):
        return {target.id}
    if type(target) is ast.Tuple:
        names = set()
        for element in target.elts:
            names |= _targets(element)
        return names
    raise ExpressionError('generator targets must be names')


class _Evaluator:
    def __init__(self, state):
        self.state = state
        self.iterations = 0

    def run(self, node, scope):
        kind = type(node)
        if kind is ast.Constant:
            return node.value
        if kind is ast.Name:
            if node.id in scope:
                return scope[node.id]
            return self.read(self.state, node.id)
        if kind is ast.Attribute:
            return self.read(self.run(node.value, scope), node.attr)
        if kind is ast.Subscript:
            return self.index(self.run(node.value, scope), node.slice, scope)
        if kind is ast.BoolOp:
            result = None
            for value in node.values:
                result = self.run(value, scope)
                if (type(node.op) is ast.And) != bool(result):
                    return result
            return result
        if kind is ast.UnaryOp:
            operand = self.run(node.operand, scope)
            if type(node.op) is ast.Not:
                return not operand
            if not _is_number(operand):
                raise ExpressionError(f'cannot negate {_describe(operand)}')
            return -operand if type(node.op) is ast.USub else +operand
        if kind is ast.BinOp:
            return self.arithmetic(node.op, self.run(node.left, scope), self.run(node.right, scope))
        if kind is ast.Compare:
            left = self.run(node.left, scope)
            for op, comparator in zip(node.ops, node.comparators):
                right = self.run(comparator, scope)
                if not self.compare(op, left, right):
                    return False
                left = right
            return True
        if kind is ast.Call:
            arguments = [self.run(argument, scope) for argument in node.args]
            name = node.func.id
            if name == 'len' and arguments and arguments[0] is None:
                raise ExpressionError('len() of a missing value')
            try:
                return FUNCTIONS[name](*arguments)
            except (TypeError, ValueError) as error:
                raise ExpressionError(f'{name}(): {error}') from None
        if kind is ast.GeneratorExp:
            return self.generate(node, 0, scope)
        raise ExpressionError(f'{kind.__name__} is not allowed in checks')  # Unreachable after validation.

    def generate(self, node, level, scope):
        generator = node.generators[level]
        iterable = self.run(generator.iter, scope)
        if iterable is None:
            iterable = ()
        if isinstance(iterable, dict):
            iterable = list(iterable)
        if not isinstance(iterable, (list, tuple, str, set, frozenset)):
            raise ExpressionError(f'cannot iterate over {_describe(iterable)}')
        for item in list(iterable):
            self.iterations += 1
            if self.iterations > MAX_ITERATIONS:
                raise ExpressionError('expression iterates too many times')
            inner = dict(scope)
            self.bind(generator.target, item, inner)
            if all(self.run(condition, inner) for condition in generator.ifs):
                if level + 1 < len(node.generators):
                    yield from self.generate(node, level + 1, inner)
                else:
                    yield self.run(node.elt, inner)

    def bind(self, target, value, scope):
        if type(target) is ast.Name:
            scope[target.id] = value
            return
        if not isinstance(value, (list, tuple)) or len(value) != len(target.elts):
            raise ExpressionError('cannot unpack value in a generator')
        for element, item in zip(target.elts, value):
            self.bind(element, item, scope)

    @staticmethod
    def read(value, key):
        if value is None:
            return None
        if isinstance(value, dict):
            return value.get(key)
        raise ExpressionError(f'cannot read .{key} of {_describe(value)}')

    def index(self, value, key_node, scope):
        if type(key_node) is ast.Slice:
            parts = [None if p is None else self.run(p, scope) for p in (key_node.lower, key_node.upper, key_node.step)]
            if value is None:
                return None
            if not isinstance(value, (list, str)) or not all(p is None or (type(p) is int) for p in parts):
                raise ExpressionError(f'cannot slice {_describe(value)}')
            if parts[2] == 0:
                raise ExpressionError('slice step cannot be zero')
            return value[slice(*parts)]
        key = self.run(key_node, scope)
        if value is None:
            return None
        if isinstance(value, dict):
            if not isinstance(key, (str, int, float, bool)) and key is not None:
                raise ExpressionError(f'cannot index an object with {_describe(key)}')
            return value.get(key if isinstance(key, str) else str(key).lower() if isinstance(key, bool) else str(key))
        if isinstance(value, (list, str)):
            if type(key) is not int:
                raise ExpressionError(f'list index must be an integer, not {_describe(key)}')
            return value[key] if -len(value) <= key < len(value) else None
        raise ExpressionError(f'cannot index {_describe(value)}')

    @staticmethod
    def arithmetic(op, left, right):
        kind = type(op)
        sequences = (str, list)
        if kind is ast.Mult and (isinstance(left, sequences) or isinstance(right, sequences)):
            sequence, count = (left, right) if isinstance(left, sequences) else (right, left)
            if type(count) is not int or len(sequence) * max(count, 0) > MAX_SEQUENCE:
                raise ExpressionError('repetition is too large or not by an integer')
            return sequence * count
        if kind is ast.Add and isinstance(left, sequences) and type(left) is type(right):
            if len(left) + len(right) > MAX_SEQUENCE:
                raise ExpressionError('concatenation is too large')
            return left + right
        if not (_is_number(left) and _is_number(right)):
            raise ExpressionError(f'cannot apply {kind.__name__} to {_describe(left)} and {_describe(right)}')
        try:
            if kind is ast.Add:
                return left + right
            if kind is ast.Sub:
                return left - right
            if kind is ast.Mult:
                return left * right
            if kind is ast.Div:
                return left / right
            if kind is ast.FloorDiv:
                return left // right
            return left % right
        except ZeroDivisionError:
            raise ExpressionError('division by zero') from None
        except OverflowError as error:
            raise ExpressionError(str(error)) from None

    @staticmethod
    def compare(op, left, right):
        kind = type(op)
        if kind is ast.Eq:
            return left == right
        if kind is ast.NotEq:
            return left != right
        if kind is ast.Is:
            return left is right if right is None or left is None or isinstance(right, bool) else left == right
        if kind is ast.IsNot:
            return not _Evaluator.compare(ast.Is(), left, right)
        if kind in (ast.In, ast.NotIn):
            if right is None:
                found = False
            elif isinstance(right, dict):
                found = left in right if isinstance(left, str) else False
            elif isinstance(right, str):
                if not isinstance(left, str):
                    raise ExpressionError(f'cannot look for {_describe(left)} in a string')
                found = left in right
            elif isinstance(right, (list, tuple, set, frozenset)):
                try:
                    found = left in right
                except TypeError:
                    found = any(left == element for element in right)
            else:
                raise ExpressionError(f'cannot test membership in {_describe(right)}')
            return found if kind is ast.In else not found
        # Ordering: a missing value is never less or greater than anything.
        if left is None or right is None:
            return False
        try:
            if kind is ast.Lt:
                return left < right
            if kind is ast.LtE:
                return left <= right
            if kind is ast.Gt:
                return left > right
            return left >= right
        except TypeError:
            raise ExpressionError(f'cannot order {_describe(left)} and {_describe(right)}') from None


def _is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _describe(value):
    if value is None:
        return 'a missing value'
    return {dict: 'an object', list: 'a list', str: 'a string', bool: 'a boolean', int: 'a number',
            float: 'a number', set: 'a set', tuple: 'a tuple'}.get(type(value), type(value).__name__)


def evaluate(expression, state):
    """Evaluate a source string or a compiled tree against a state dict. Raises ExpressionError."""
    node = compile_expression(expression) if isinstance(expression, str) else expression
    evaluator = _Evaluator(state if isinstance(state, dict) else {})
    try:
        result = evaluator.run(node, {})
        if type(result).__name__ == 'generator':
            result = list(result)
        return result
    except RecursionError:
        raise ExpressionError('expression is nested too deeply') from None
    except MemoryError:
        raise ExpressionError('expression used too much memory') from None


def holds(expression, state):
    """True when the expression is truthy for this state."""
    return bool(evaluate(expression, state))
