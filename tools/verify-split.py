# Verify a CLAUDE.md split: every "## " section of the original exists verbatim exactly once in the new CLAUDE.md or docs/claude/*.md; new CLAUDE.md <= 20000 chars; every topic doc is referenced from CLAUDE.md.
import re,glob,sys
import argparse
parser=argparse.ArgumentParser(description=__doc__ or 'Verify a CLAUDE.md split without changing section content.')
parser.add_argument('--original',default='.claude-md-orig.tmp',help='original CLAUDE.md backup (default: .claude-md-orig.tmp)')
parser.add_argument('--index',default='CLAUDE.md',help='new index (default: CLAUDE.md)')
parser.add_argument('--docs',default='docs/claude',help='topic document directory (default: docs/claude)')
args=parser.parse_args()
orig=open(args.original,encoding='utf-8').read()
new=open(args.index,encoding='utf-8').read()
docs={p:open(p,encoding='utf-8').read() for p in sorted(glob.glob(args.docs+'/*.md'))}
pool=new+'\n'+'\n'.join(docs.values())
secs=[s.strip() for s in re.split(r'(?m)^(?=## )',orig)[1:]]
miss=[s.split('\n')[0] for s in secs if s not in pool]
dup=[s.split('\n')[0] for s in secs if pool.count(s)>1]
unref=[p for p in docs if p not in new]
print(f'sections {len(secs)} missing {len(miss)} duplicated {len(dup)} | CLAUDE.md {len(new)} chars | docs files {len(docs)} unreferenced {len(unref)}')
for x in miss+dup+unref: print('  !',x[:80])
ok=not miss and not dup and not unref and len(new)<=20000
print('PASS' if ok else 'FAIL'); sys.exit(0 if ok else 1)
