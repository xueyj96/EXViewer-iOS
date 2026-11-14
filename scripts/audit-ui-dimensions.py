#!/usr/bin/env python3
"""Inventory ExHViewer Swift UI declarations and geometry without executing the app.

This is a lexical source inventory. A declaration or call site is not a count of
rendered controls, and inherited styles and conditional geometry need review.
"""
import argparse
import bisect
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[1]
CONTROLS = {
    "Button", "NavigationLink", "Link", "ShareLink", "Menu", "Picker",
    "Toggle", "Slider", "Stepper", "TextField", "SecureField", "TextEditor",
    "UISlider", "UIButton", "UILabel", "UIImageView", "WKWebView", "UIActivityIndicatorView", "ProgressView", "DisclosureGroup", "LabeledContent", "AsyncImage",
    "Text", "Label", "Image", "Divider", "List", "Section", "ScrollView",
    "LazyVGrid", "LazyHGrid", "LazyVStack", "LazyHStack", "HStack", "VStack",
    "ZStack", "Grid", "GeometryReader", "NavigationStack", "TabView", "Form",
    "ContentUnavailableView", "DatePicker", "ColorPicker", "Gauge", "MultiDatePicker",
}
MODIFIERS = {
    "frame", "padding", "font", "fontWeight", "lineSpacing", "lineLimit",
    "minimumScaleFactor", "fixedSize", "cornerRadius", "clipShape",
    "contentShape", "controlSize", "buttonStyle", "toggleStyle", "pickerStyle",
    "listRowInsets", "listRowSpacing", "contentMargins", "safeAreaPadding",
    "safeAreaInset", "ignoresSafeArea", "scaledToFit", "scaledToFill",
    "aspectRatio", "offset", "position", "scaleEffect", "dynamicTypeSize",
    "presentationDetents", "presentationCornerRadius", "overlay", "background",
    "stroke", "strokeBorder", "opacity", "tint", "foregroundStyle", "listStyle",
    "alert", "confirmationDialog", "sheet", "fullScreenCover", "contextMenu",
    "keyboardType", "textInputAutocapitalization", "truncationMode", "imageScale", "lineLimit", "submitLabel", "scrollDismissesKeyboard", "navigationDestination", "presentationDragIndicator", "contentTransition", "transition", "animation", "layoutPriority",
}
GEOMETRY = {"CGRect", "CGSize", "EdgeInsets", "UIEdgeInsets", "RoundedRectangle", "Capsule", "Circle", "Rectangle", "GridItem", "UIBezierPath"}
LAYOUT_CONTAINERS = {"HStack", "VStack", "ZStack", "LazyHStack", "LazyVStack", "LazyVGrid", "LazyHGrid", "Grid"}
UIKIT_FONTS = {"systemFont", "monospacedDigitSystemFont", "preferredFont"}
TOKEN = re.compile(r'[A-Za-z_][A-Za-z_0-9]*|[0-9]+(?:\.[0-9]+)?|[^\s]')
UI_PROTOCOLS = {"UIView", "UIViewController", "UISlider", "WKWebView", "View", "ViewModifier", "ButtonStyle", "ToggleStyle", "Layout", "UIViewRepresentable", "UIViewControllerRepresentable"}


def skip_comment(source, start):
    depth = 1
    i = start + 2
    while i < len(source) and depth:
        if source.startswith('/*', i):
            depth += 1
            i += 2
        elif source.startswith('*/', i):
            depth -= 1
            i += 2
        else:
            i += 1
    return i


def starts_string(source, start):
    return source[start] == '"' or (source[start] == '#' and bool(re.match(r'#+"', source[start:])))


def skip_interpolation(source, start):
    depth = 1
    i = start
    while i < len(source) and depth:
        if starts_string(source, i):
            i = skip_string(source, i)
        elif source.startswith('/*', i):
            i = skip_comment(source, i)
        elif source.startswith('//', i):
            end = source.find('\n', i)
            i = len(source) if end < 0 else end
        else:
            if source[i] == '(':
                depth += 1
            elif source[i] == ')':
                depth -= 1
            i += 1
    return i


def skip_string(source, start):
    i = start
    while source[i] == '#':
        i += 1
    hashes = '#' * (i-start)
    quote = '"""' if source.startswith('"""', i) else '"'
    closing = quote + hashes
    interpolation = '\\' + hashes + '('
    i += len(quote)
    while i < len(source):
        if source.startswith(closing, i):
            return i + len(closing)
        if source.startswith(interpolation, i):
            i = skip_interpolation(source, i + len(interpolation))
        elif not hashes and source[i] == '\\':
            i += 2
        else:
            i += 1
    return i


def tokens(source):
    """Skip comments and string bodies so their words cannot become UI calls."""
    result = []
    i = 0
    while i < len(source):
        if source.startswith('//', i):
            end = source.find('\n', i)
            i = len(source) if end < 0 else end
        elif source.startswith('/*', i):
            i = skip_comment(source, i)
        elif starts_string(source, i):
            start = i
            i = skip_string(source, i)
            result.append(('<string>', start, i))
        elif source[i].isspace():
            i += 1
        else:
            match = TOKEN.match(source, i)
            result.append((match.group(), i, match.end()))
            i = match.end()
    return result


def delimiters(items):
    stack = []
    pairs = {}
    opening = {'(': ')', '[': ']', '{': '}'}
    for i, (value, _, _) in enumerate(items):
        if value in opening:
            stack.append((value, i))
        elif value in opening.values() and stack and opening[stack[-1][0]] == value:
            _, start = stack.pop()
            pairs[start] = i
    return pairs


def conditions(source):
    stack = []
    rows = []
    for line in source.splitlines():
        text = line.strip()
        if text.startswith('#if '):
            stack.append(text[4:])
        elif text.startswith('#elseif ') and stack:
            stack[-1] = text[8:]
        elif text == '#else' and stack:
            stack[-1] = 'else of ' + stack[-1]
        elif text == '#endif' and stack:
            stack.pop()
        rows.append(list(stack))
    return rows


def inventory():
    sources = []
    declarations = []
    definitions = []
    for path in sorted((ROOT / 'App').rglob('*.swift')):
        source = path.read_text()
        items = tokens(source)
        pairs = delimiters(items)
        newlines = [i for i, c in enumerate(source) if c == '\n']
        line_number = lambda offset: bisect.bisect_left(newlines, offset) + 1
        flags = conditions(source)
        declared = []
        qa_ranges = []
        for i, (value, start, _) in enumerate(items):
            if value != 'if':
                continue
            brace = next((j for j in range(i+1, len(items)) if items[j][0] == '{'), None)
            if brace is None or brace not in pairs:
                continue
            condition = source[start:items[brace][1]]
            if re.search(r'\bif\s+AppMode\.qa\b', condition) or ('--qa-' in condition and '.contains(' in condition and '!ProcessInfo' not in condition):
                qa_ranges.append((items[brace][1], items[pairs[brace]][2]))
        for i, (value, start, _) in enumerate(items[:-1]):
            if value not in {'struct', 'class', 'enum', 'extension'}:
                continue
            name = items[i + 1][0]
            if not re.fullmatch(r'[A-Za-z_]\w*', name):
                continue
            brace = next((j for j in range(i + 2, len(items)) if items[j][0] in {'{', ';'}), None)
            if brace is None or items[brace][0] != '{' or brace not in pairs:
                continue
            signature = source[start:items[brace][1]].strip()
            protocols = set(re.findall(r'\b[A-Za-z_]\w*\b', signature))
            ui = bool(protocols & UI_PROTOCOLS or any(p.startswith('UI') or p.startswith('WK') for p in protocols))
            entry = dict(name=name, kind=value, line=line_number(start), signature=signature,
                         ui=ui, conditions=flags[line_number(start)-1],
                         end_line=line_number(items[pairs[brace]][1]))
            declared.append(entry)
        production_ui = any(d['ui'] for d in declared)
        qa = bool(re.search(r'QA|Readback|SelectionPerformanceProbe', path.stem))
        relative = str(path.relative_to(ROOT))
        calls = []
        geometry_properties = []
        if production_ui:
            for line, text in enumerate(source.splitlines(), 1):
                definition = re.search(r'\b(?:let|var)\s+(\w+)', text)
                if definition and re.search(r'size|height|width|inset|radius|spacing|font|stroke|caption|padding|corner|track|thumb', definition.group(1), re.I):
                    geometry_properties.append(dict(line=line, source=text.strip(), conditions=flags[line-1]))
                elif re.search(r'\.(?:cornerRadius|font|contentInset|separatorInset|minimumTrackTintColor)\s*=', text):
                    geometry_properties.append(dict(line=line, source=text.strip(), conditions=flags[line-1]))
            for i, (name, start, _) in enumerate(items):
                if i+1 >= len(items) or items[i+1][0] not in {'(', '{'}:
                    continue
                is_method = i > 0 and items[i-1][0] == '.'
                kind = 'modifier' if is_method and name in MODIFIERS else None
                if is_method and name in UIKIT_FONTS:
                    kind = 'uikit_font'
                if not is_method and name in CONTROLS:
                    kind = 'primitive'
                if not is_method and name in GEOMETRY:
                    kind = 'geometry'
                if kind is None or (i > 0 and items[i-1][0] in {'func', 'struct', 'class', 'enum'}):
                    continue
                if items[i+1][0] == '{' and i > 0 and items[i-1][0] in {'>', ':'}:
                    continue  # Return types and superclass declarations are not constructors.
                line = line_number(start)
                owners = [d for d in declared if d['line'] <= line <= d['end_line']]
                owner = min(owners, key=lambda d: d['end_line']-d['line'])['name'] if owners else None
                qa_owner = any('QA' in d['name'] for d in owners)
                runtime_qa = qa_owner or any(a <= start <= b for a,b in qa_ranges)
                entry = dict(kind=kind, name=name, line=line, owner=owner, conditions=flags[line-1],
                             runtime_qa=runtime_qa,
                             evidence_level='source_callsite', effective_runtime_size='UNKNOWN')
                if i+1 < len(items) and items[i+1][0] == '(' and i+1 in pairs:
                    end = pairs[i+1]
                    if kind != 'primitive' or name in LAYOUT_CONTAINERS:
                        entry['arguments'] = ' '.join(source[items[i+1][2]:items[end][1]].split())
                calls.append(entry)
        sources.append(dict(path=relative, sha256=hashlib.sha256(source.encode()).hexdigest(),
                            scope='qa_ui' if qa and production_ui else 'production_ui' if production_ui else 'non_ui',
                            lines=len(source.splitlines()), declarations=declared, callsites=calls,
                            geometry_properties=geometry_properties))
        definitions.extend(dict(file=relative, **d) for d in declared)
        declarations.extend(dict(file=relative, **d) for d in declared if d['ui'])
    names = {d['name'] for d in declarations if d['kind'] != 'extension'} | {'FeedChrome', 'AppShape', 'FloatingChrome', 'TagChipMetrics', 'LibraryCardMetrics'}
    references = {name: [] for name in sorted(names)}
    for item in sources:
        # References are lexical name uses, including types and constructors.
        source = (ROOT/item['path']).read_text()
        for value, start, _ in tokens(source):
            if value in names:
                references[value].append(dict(file=item['path'], line=source.count('\n', 0, start)+1))
    prod = [s for s in sources if s['scope']=='production_ui']
    all_calls = [c for s in prod for c in s['callsites']]
    def debug_only(call):
        return call.get('runtime_qa', False) or 'QA' in (call.get('owner') or '') or any(condition.startswith('DEBUG') or condition.startswith('targetEnvironment(simulator)')
                   for condition in call['conditions'])
    calls = [c for c in all_calls if not debug_only(c)]
    standard_path = ROOT/'docs/ui-dimensions.md'
    standard = standard_path.read_text()
    families = []
    table = standard.split('## 全组件规格目录\n', 1)[1].split('\n## ', 1)[0]
    for line in table.splitlines():
        if not line.startswith('| ') or line.startswith('| 类别') or line.startswith('| ---'):
            continue
        category, implementation, current, next_step = [part.strip() for part in line.strip('|').split('|')]
        symbols = re.findall(r'`([^`]+)`', implementation)
        origins = []
        for symbol in symbols:
            name = symbol.split('.')[0]
            origins.extend(dict(file=d['file'], line=d['line'], name=d['name']) for d in definitions if d['name']==name)
        referenced = sorted({(r['file'],r['line']) for symbol in symbols
                             for r in references.get(symbol.split('.')[0],[])})
        families.append(dict(category=category, shared_implementation=implementation,
                             current=current, recommendation=next_step, verification='source_review',
                             actual_runtime_size='UNKNOWN unless the standard document lists a specific test',
                             sources=origins,
                             reference_sites=[dict(file=f,line=n) for f,n in referenced]))
    report = dict(schema_version=2, project='ExHViewer', source_root='App', source_commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'],cwd=ROOT,text=True).strip(),
                  method='Lexical Swift source inventory. Call sites are not rendered instance counts. No runtime measurements.',
                  limitations=['Function/closure inheritance and layout proposals are not evaluated.',
                               'Inline conditional compilation is retained as source conditions, not compiled.',
                               'QA files are listed separately; production files can still contain conditional QA code.',
                               'Control calls inside Swift string interpolation are not scanned.',
                               'Recognized positive AppMode.qa / --qa- branches and QA owners are excluded from classified counts; indirect runtime QA flags may remain.',
                               'Media geometry in MediaCanvas is rendering geometry, not a control target size.',
                               'source_commit is a pointer only; per-file hashes describe the current possibly dirty working tree.',
                               'UIKit geometry is captured at CGRect/CGSize call sites; property assignments require manual review.'],
                  counts=dict(source_files=len(sources), scopes=dict(Counter(s['scope'] for s in sources)),
                              component_families=len(families),
                              ui_declarations=len(declarations), production_ui_file_callsites=len(all_calls),
                              classified_debug_or_qa_callsites=sum(debug_only(c) for c in all_calls),
                              classified_production_ui_callsites=len(calls),
                              classified_production_callsites_by_kind=dict(Counter(c['kind'] for c in calls)),
                              classified_production_callsites_by_name=dict(sorted(Counter(c['name'] for c in calls).items()))),
                  standard_file=str(standard_path.relative_to(ROOT)),
                  standard_sha256=hashlib.sha256(standard.encode()).hexdigest(),
                  component_families=families, sources=sources, ui_declaration_references=references)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Check the tracked inventory matches the current source.')
    args = parser.parse_args()
    destination = ROOT/'docs/ui-control-inventory.json'
    report = inventory()
    if args.check:
        previous = json.loads(destination.read_text())
        # A documentation-only commit must not invalidate an otherwise identical inventory.
        previous.pop('source_commit', None)
        comparable = dict(report)
        comparable.pop('source_commit', None)
        if previous != comparable:
            raise SystemExit('UI source changed. Regenerate with python3 scripts/audit-ui-dimensions.py')
    else:
        destination.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps(report['counts'], ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
