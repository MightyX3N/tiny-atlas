"""Reassemble base64 chunks returned by browser-pane JS (B64START...B64END) into a decoded file.
usage: grab.py OUT [--gunzip] toolresult1 toolresult2 ..."""
import sys, json, re, base64, gzip
out = sys.argv[1]; args = sys.argv[2:]; gz = False
if args and args[0] == '--gunzip': gz = True; args = args[1:]
s = ''
for f in args:
    t = ''.join(x['text'] for x in json.load(open(f)))
    s += re.search(r'B64START([A-Za-z0-9+/=]*)B64END', t).group(1)
data = base64.b64decode(s)
if gz: data = gzip.decompress(data)
open(out, 'wb').write(data); print(out, len(data))
