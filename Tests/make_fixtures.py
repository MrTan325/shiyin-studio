#!/usr/bin/env python3
"""Build a valid raw-RGB QuickTime file without an external encoder."""
import pathlib
import struct
import sys

def u32(*values): return struct.pack('>' + 'I' * len(values), *values)
def u16(*values): return struct.pack('>' + 'H' * len(values), *values)
def atom(kind, payload): return u32(len(payload)+8) + kind.encode('ascii') + payload
matrix = u32(0x10000,0,0,0,0x10000,0,0,0,0x40000000)
ftyp = atom('ftyp', b'qt  ' + u32(0) + b'qt  ')
width,height,frames,fps = 320,180,24,24
sample_size = width*height*3
mvhd = atom('mvhd', u32(0,0,0,fps,frames,0x10000) + u16(0x100) + bytes(10) + matrix + bytes(24) + u32(2))
tkhd = atom('tkhd', u32(7,0,0,1,0,frames) + bytes(8) + u16(0,0,0,0) + matrix + u32(width<<16,height<<16))
mdhd = atom('mdhd',u32(0,0,0,fps,frames)+u16(0,0))
hdlr = atom('hdlr',u32(0,0)+b'vide'+bytes(12)+b'Video\0')
vmhd = atom('vmhd',u32(1)+u16(0,0,0,0))
dref = atom('dref',u32(0,1)+atom('url ',u32(1)))
dinf = atom('dinf',dref)
entry = bytes(6)+u16(1,0,0)+bytes(4)+u32(0,0)+u16(width,height)+u32(72<<16,72<<16,0)+u16(1)+bytes(32)+u16(24,0xffff)
stsd = atom('stsd',u32(0,1)+atom('raw ',entry))
stts = atom('stts',u32(0,1,frames,1))
stsc = atom('stsc',u32(0,1,1,frames,1))
stsz = atom('stsz',u32(0,sample_size,frames))
stco = atom('stco',u32(0,1,len(ftyp)+8))
stbl = atom('stbl',stsd+stts+stsc+stsz+stco)
minf = atom('minf',vmhd+dinf+stbl)
mdia = atom('mdia',mdhd+hdlr+minf)
trak = atom('trak',tkhd+mdia)
moov = atom('moov',mvhd+trak)
output = pathlib.Path(sys.argv[1]); output.parent.mkdir(parents=True,exist_ok=True)
output.write_bytes(ftyp+atom('mdat',bytes(sample_size*frames))+moov)
