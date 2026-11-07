"""Decode a __packBin transfer (gzip of [u32 namelen][u32 datalen][name][data]...) into {name: bytes}."""
import base64, gzip, json, re, struct, sys
def load(files):
    s = ''
    for f in files:
        t = ''.join(x['text'] for x in json.load(open(f)))
        s += re.search(r'B64START([A-Za-z0-9+/=]*)B64END', t).group(1)
    raw = gzip.decompress(base64.b64decode(s)); out = {}; i = 0
    while i < len(raw):
        nl, dl = struct.unpack('>II', raw[i:i + 8]); i += 8
        name = raw[i:i + nl].decode(); i += nl; out[name] = raw[i:i + dl]; i += dl
    return out
