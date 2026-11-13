#!/usr/bin/env python3
"""Render the approved notification board from the shipped Android vectors."""

from pathlib import Path
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
ANDROID = '{http://schemas.android.com/apk/res/android}'
ATTRIBUTES = {
    'pathData': 'd',
    'strokeWidth': 'stroke-width',
    'strokeLineCap': 'stroke-linecap',
    'strokeLineJoin': 'stroke-linejoin',
}


def drawing(element):
    if element.tag == 'group':
        x = element.get(ANDROID + 'translateX', '0')
        y = element.get(ANDROID + 'translateY', '0')
        sx = element.get(ANDROID + 'scaleX', '1')
        sy = element.get(ANDROID + 'scaleY', '1')
        result = ET.Element('g', transform=f'translate({x} {y}) scale({sx} {sy})')
        result.extend(drawing(child) for child in element)
        return result
    if element.tag != 'path':
        raise ValueError(f'Unsupported vector element: {element.tag}')
    result = ET.Element('path')
    for source, target in ATTRIBUTES.items():
        value = element.get(ANDROID + source)
        if value is not None:
            result.set(target, value)
    for source, target in [('fillColor', 'fill'), ('strokeColor', 'stroke')]:
        value = element.get(ANDROID + source)
        if value is not None:
            if value not in ('#FFFFFFFF', '#00000000'):
                raise ValueError(f'Expected monochrome notification artwork: {value}')
            result.set(target, 'none' if value == '#00000000' else 'currentColor')
    return result


def symbol(name, filename):
    source = ROOT / 'android/app/src/main/res/drawable' / filename
    vector = ET.parse(source).getroot()
    assert vector.get(ANDROID + 'viewportWidth') == '24'
    assert vector.get(ANDROID + 'viewportHeight') == '24'
    content = ''.join(ET.tostring(drawing(child), encoding='unicode') for child in vector)
    return f'<symbol id="{name}" viewBox="0 0 24 24">{content}</symbol>'


def main():
    parts = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="1536" height="720" '
        'viewBox="0 0 1536 720" role="img" aria-labelledby="title description">',
        '<title id="title">Wing notification identity — approved 16 September 2026</title>',
        '<desc id="description">Hermes caduceus for permanent connection; messenger wing '
        'for every chat notification. Exact app vectors at enlarged, 24 px and 18 px sizes '
        'on light and dark backgrounds.</desc>',
        '<defs>',
        symbol('connection', 'ic_stat_connection.xml'),
        symbol('chat', 'ic_stat_wing.xml'),
        '</defs>',
        '<rect width="1536" height="720" fill="#FFF9EB"/>',
        '<rect y="426" width="1536" height="294" fill="#0C304A"/>',
        '<g font-family="Arial, sans-serif">',
        '<text x="48" y="54" font-size="22" letter-spacing="2" fill="#0C304A">'
        'WING / NOTIFICATION IDENTITY</text>',
        '<text x="1488" y="54" text-anchor="end" font-size="18" fill="#0C304A">'
        'Approved · 16 September 2026</text>',
        '<path d="M48 82H1488" stroke="#0C304A" stroke-opacity=".2"/>',
    ]
    for x, name, title, subtitle in [
        (48, 'connection', 'Permanent connection', 'Hermes’ caduceus'),
        (816, 'chat', 'Each chat notification', 'Wing’s messenger wing'),
    ]:
        parts.extend([
            f'<text x="{x}" y="144" font-size="34" fill="#0C304A">{title}</text>',
            f'<text x="{x}" y="180" font-size="21" fill="#0C304A">{subtitle}</text>',
        ])
        for y, color in [(226, '#0C304A'), (478, '#FFF9EB')]:
            parts.append(f'<g color="{color}">')
            for offset, size in [(0, 128), (238, 24), (372, 18)]:
                top = y if size == 128 else y + (128 - size) / 2
                parts.append(
                    f'<use href="#{name}" x="{x + offset}" y="{top}" '
                    f'width="{size}" height="{size}"/>'
                )
                label = 'Enlarged' if size == 128 else f'{size} px'
                parts.append(
                    f'<text x="{x + offset}" y="{y + 164}" font-size="17" '
                    f'fill="{color}">{label}</text>'
                )
            parts.append('</g>')
    parts.extend([
        '<text x="48" y="688" font-size="18" fill="#C6EED5">'
        'Monochrome app vectors · Android supplies the status-bar tint</text>',
        '</g></svg>',
    ])
    target = ROOT / 'build/design-previews/notification-identity-board.svg'
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text('\n'.join(parts) + '\n')
    print(target.relative_to(ROOT))


if __name__ == '__main__':
    main()
