#!/usr/bin/env python3
"""Build a small Unicode console font from the installer prompt repertoire."""
from pathlib import Path
import argparse,hashlib,importlib.util,json,struct
from PIL import Image,ImageDraw,ImageFont
p=argparse.ArgumentParser();p.add_argument('--font',required=True);p.add_argument('--out',default=str(Path(__file__).resolve().parent.parent/'assets'));a=p.parse_args()
here=Path(__file__).resolve().parent;out=Path(a.out);out.mkdir(parents=True,exist_ok=True)
spec=importlib.util.spec_from_file_location('iso_check',here/'check-iso.py');checker=importlib.util.module_from_spec(spec);spec.loader.exec_module(checker)
runtime=''.join(checker.strip_comments((here/n).read_text(encoding='utf8')) for n in ['installer.sh','init-installer.sh'])
build=(here/'build-iso.sh').read_text(encoding='utf8');grub=build.split('<<CFG\n',1)[1].split('\nCFG',1)[0]
extra=sorted({c for c in runtime+grub if ord(c)>127})
chars=[chr(i) for i in range(128)]+extra
if len(chars)>512:raise SystemExit('Installer glyph repertoire exceeds the Linux console 512-glyph limit')
font=ImageFont.truetype(a.font,20);width,height=16,24;data=bytearray();table=bytearray()
for i in range(512):
    c=chars[i] if i<len(chars) else None
    bitmap=Image.new('L',(width,height))
    if c and ord(c)>=33 and ord(c)!=127:
        advance=max(1,int(font.getlength(c)+1));glyph=Image.new('L',(advance,height))
        ImageDraw.Draw(glyph).text((0,height-4),c,font=font,fill=255,anchor='ls')
        if advance>width:glyph=glyph.resize((width,height),Image.Resampling.LANCZOS)
        bitmap.paste(glyph,((width-glyph.width)//2,0))
    for y in range(height):
        row=0
        for x in range(width):row=(row<<1)|(bitmap.getpixel((x,y))>=96)
        data.extend(row.to_bytes(2,'big'))
    if c:table.extend(c.encode('utf8'))
    table.append(255)
psf=struct.pack('<8I',0x864ab572,0,32,1,512,width*height//8,height,width)+data+table
(out/'installer-console.psf').write_bytes(psf)
grub_chars=sorted(set(range(32,127))|set(range(0x2500,0x2580))|{ord(c) for c in extra})
(out/'installer-font-ranges.txt').write_text(','.join('0x%x-0x%x'%(n,n) for n in grub_chars),encoding='ascii')
manifest={'family':'Console Installer CJK','source':'Noto Sans CJK SC Regular (SIL OFL 1.1)','source_sha256':hashlib.sha256(Path(a.font).read_bytes()).hexdigest(),
          'width':width,'height':height,'mapped_glyphs':len(chars),'unicode':extra,'psf_sha256':hashlib.sha256(psf).hexdigest()}
(out/'installer-font-coverage.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf8',newline='\n')
print(json.dumps({'mapped_glyphs':len(chars),'psf_bytes':len(psf)}))
