#!/usr/bin/env python3
"""Generate vector templates and embed them in the SwiftBar plugin (stdlib only)."""
import base64
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
# 18 pt canvas, 1.5 pt rounded strokes. Coordinates also serve as editable sources.
BRIDGE = 'M 1.5 5.5 L 16.5 5.5 M 3.5 5.5 L 3.5 14.5 M 14.5 5.5 L 14.5 14.5 M 3.5 14.5 C 3.5 7 14.5 7 14.5 14.5'
BROKEN = 'M 1.5 5.5 L 7 5.5 M 11 5.5 L 16.5 5.5 M 3.5 5.5 L 3.5 14.5 M 14.5 5.5 L 14.5 14.5 M 3.5 14.5 C 3.5 11 5 9 7 9 M 11 9 C 13 9 14.5 11 14.5 14.5'
SLASH = 'M 3 2.5 L 15 15.5'
# Knockout around the slash keeps it legible without adding opaque white pixels.
KNOCKOUT = 'M 1.7 3.7 L 4.3 1.3 L 16.3 14.3 L 13.7 16.7 Z'


def pdf_path(path):
    tokens = path.split()
    result = []
    counts = {'M': 2, 'L': 2, 'C': 6, 'Z': 0}
    while tokens:
        op = tokens.pop(0)
        count = counts[op]
        coords, tokens = tokens[:count], tokens[count:]
        result.append(' '.join(coords + [{'M': 'm', 'L': 'l', 'C': 'c', 'Z': 'h'}[op]]))
    return '\n'.join(result)


def template_pdf(path, stopped=False):
    # Native PDF points preserve the 18 x 18 logical size at every display scale.
    stream = 'q\n1 0 0 -1 0 18 cm\n0 G\n1.5 w\n1 J\n1 j\n'
    if stopped:
        stream += 'q\n0 0 18 18 re\n' + pdf_path(KNOCKOUT) + '\nW* n\n'
    stream += pdf_path(path) + '\nS\n'
    if stopped:
        stream += 'Q\n' + pdf_path(SLASH) + '\nS\n'
    stream += 'Q\n'
    content = stream.encode('ascii')
    objects = [
        b'<< /Type /Catalog /Pages 2 0 R >>',
        b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 18 18] /Resources << >> /Contents 4 0 R >>',
        f'<< /Length {len(content)} >>\nstream\n'.encode() + content + b'endstream',
    ]
    data = b'%PDF-1.4\n'
    offsets = [0]
    for index, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data += f'{index} 0 obj\n'.encode() + obj + b'\nendobj\n'
    xref = len(data)
    data += b'xref\n0 5\n0000000000 65535 f \n'
    data += b''.join(f'{offset:010} 00000 n \n'.encode() for offset in offsets[1:])
    data += f'trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode()
    return data


assignments = []
for state, path in [('connected', BRIDGE), ('disconnected', BROKEN), ('stopped', BRIDGE)]:
    stopped = state == 'stopped'
    attributes = 'fill="none" stroke="black" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"'
    svg = '<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18">\n'
    svg += f'  <title>Muse Bridge: {state}</title>\n'
    if stopped:
        svg += f'  <defs><mask id="slash"><rect width="18" height="18" fill="white"/><path d="{KNOCKOUT}"/></mask></defs>\n'
    mask = ' mask="url(#slash)"' if stopped else ''
    svg += f'  <path d="{path}" {attributes}{mask}/>\n'
    if stopped:
        svg += f'  <path d="{SLASH}" {attributes}/>\n'
    svg += '</svg>\n'
    (ROOT / 'mac-menu-bar' / 'icons' / f'bridge-{state}.svg').write_text(svg)
    encoded = base64.b64encode(template_pdf(path, stopped)).decode()
    assignments.append(f'ICON_{state.upper()}="{encoded}"')

plugin = ROOT / 'mac-menu-bar' / 'muse-bridge.10s.sh'
text = plugin.read_text()
text, count = re.subn(r'# BEGIN GENERATED ICONS\n.*?# END GENERATED ICONS',
                      '# BEGIN GENERATED ICONS\n' + '\n'.join(assignments) + '\n# END GENERATED ICONS',
                      text, flags=re.DOTALL)
assert count == 1, 'Missing generated icon markers'
plugin.write_text(text)
