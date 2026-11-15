"""Add #+findex and #+vindex lines to readq.org for the names it mentions.

Run by `make info'.  It reads the commands and options of readq from
the files given (one name per line, and "KEY COMMAND" lines for C-c r) and puts index entries right after
each heading whose own text names them, at most three per name."""
import re, sys

org, cmds, opts = sys.argv[1], set(open(sys.argv[2]).read().split()), set(open(sys.argv[3]).read().split())
# "KEY COMMAND" lines: the commands of the C-c r map, found from their keys.
keys = dict(line.split(' ', 1) for line in open(sys.argv[4]).read().splitlines() if ' ' in line)
text = re.sub(r'(?m)^#\+[fv]index: .*\n', '', open(org).read())
chunks = re.split(r'(?m)^(?=\*+ )', text)
counts, out = {}, []
for ch in chunks:
    m = re.match(r'(\*+ [^\n]*\n(?::PROPERTIES:\n(?:[^\n]*\n)*?:END:\n)?)(.*)', ch, re.S)
    if not m or 'index' in m.group(1).lower():
        out.append(ch)
        continue
    head, body = m.group(1), m.group(2)
    lines = []
    named = re.findall(r'=(readq[a-z0-9-]*)=', body)
    named += [keys[k] for k in re.findall(r'~(?:C-u )*C-c r (\S)~', body) if k in keys]
    for name in dict.fromkeys(named):
        for kind, names in (('findex', cmds), ('vindex', opts)):
            if name in names:
                counts[(kind, name)] = counts.get((kind, name), 0) + 1
                if counts[(kind, name)] <= 3:
                    lines.append('#+%s: %s' % (kind, name))
    out.append(head + ''.join(l + '\n' for l in lines) + body)
open(org, 'w').write(''.join(out))
