"""Isolated installer orchestration tests; no real Docker, DNS, CF or deployment."""
import json, os, pathlib, subprocess, tempfile, unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]
MOCK = r'''#!/usr/bin/env python3
import sys,os,json,pathlib
p=pathlib.Path(os.environ['FIXTURE']);name=pathlib.Path(sys.argv[0]).name;a=sys.argv[1:]
def out(x):print(x);sys.exit(0)
if name=='getent':out('127.0.0.1')
if name in ('ss','sleep','apparmor_parser','flock'):sys.exit(0)
if name=='docker':
 with (p/'calls').open('a') as f:f.write(json.dumps(a)+'\n')
 if a[:2]==['image','inspect']:out('sha256:fixture')
 if a[:2]==['network','inspect']:
  if '-f' in a:out('gateway')
  sys.exit(0)
 if a[:2]==['container','inspect'] or (a and a[0]=='inspect'):
  target=a[-1]
  if target=='vps-proxy-caddy':
   if not (p/'gateway').exists():sys.exit(1)
   out('gateway' if a[0]=='inspect' else 'true')
  if '-f' in a and 'IPAddress' in a[a.index('-f')+1]:out('172.18.0.2')
  if a[0]=='inspect':out(os.environ.get('DIRECT','direct.example.com'))
  sys.exit(0)
 if a and a[0]=='run':
  target=a[a.index('--name')+1]
  if target=='vps-proxy-caddy':(p/'gateway').touch()
  out(target)
 sys.exit(0)
if name=='curl':
 url=next(x for x in a if x.startswith(('http://','https://')));status='400';body='{"error":"missing_key"}'
 if os.environ.get('WORKER'):
  status='200';body='{"error":"missing_link"}'
 if '/real-play' in url:status='200';body='#EXTM3U\n#EXTINF:4,\nhttps://cf.example.com/segment.jpeg\n'
 if os.environ.get('FAIL_CF') and url.startswith('https://cf.example.com'):status='502';body='failed'
 cfg=(p/'state/sites/direct.example.com.caddy')
 content=cfg.read_text() if cfg.exists() else ''
 import re
 release=re.search(r'header @deployment X-VPS-Deploy (\S+)',content)
 if '--dump-header' in a:pathlib.Path(a[a.index('--dump-header')+1]).write_text('X-VPS-Deploy: '+(release.group(1) if release else '')+'\n')
 if '--output' in a:pathlib.Path(a[a.index('--output')+1]).write_text(body)
 print(status,end='');sys.exit(0)
sys.exit(1)
'''
class Install(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.p=pathlib.Path(self.tmp.name);(self.p/'bin').mkdir()
  script=(ROOT/'install.sh').read_text().replace('state=/opt/vps-proxy','state='+str(self.p/'state'))
  script=script.replace('[[ $OSTYPE == linux* && $EUID == 0 ]]', '[[ 1 == 1 ]]').replace('SECONDS + 180','SECONDS + 0').replace('SECONDS + 30','SECONDS + 0')
  self.script=self.p/'install.sh';self.script.write_text(script)
  for name in ['docker','curl','getent','ss','sleep','apparmor_parser','flock']:
   f=self.p/'bin'/name;f.write_text(MOCK);f.chmod(0o700)
  self.env=dict(os.environ,PATH=str(self.p/'bin')+':'+os.environ['PATH'],FIXTURE=str(self.p))
 def tearDown(self):self.tmp.cleanup()
 def run_install(self,dual=True,env=None,extra=(),image='ghcr.io/yjscms/missav-proxy:v1.0.1'):
  args=['direct.example.com']+(['cf.example.com'] if dual else [])+[image,'--local']+list(extra)
  return subprocess.run(['bash',str(self.script),*args],capture_output=True,text=True,env=dict(self.env,**(env or {})))
 def config(self):return (self.p/'state/sites/direct.example.com.caddy').read_text()
 def calls(self):return [json.loads(x) for x in (self.p/'calls').read_text().splitlines()]
 def test_dual_and_upgrade(self):
  r=self.run_install(extra=['--verify-path','/real-play','--verify-body','#EXTM3U']);self.assertEqual(r.returncode,0,r.stderr)
  first=self.config();self.assertIn('http://cf.example.com {',first);self.assertIn('header_up X-Forwarded-Proto https',first)
  upstreams=[x.strip() for x in first.splitlines() if x.strip().startswith('reverse_proxy')];self.assertEqual(upstreams[0],upstreams[1])
  self.assertEqual(len([x for x in self.calls() if x[:1]==['run']]),2) # one business, one gateway
  self.assertIn('https://cf.example.com/',r.stdout)
  r=self.run_install(dual=False);self.assertEqual(r.returncode,0,r.stderr);self.assertIn('http://cf.example.com',self.config());self.assertNotEqual(first,self.config())
  self.assertTrue(any(x[:2]==['rm','-f'] and x[-1]!='vps-proxy-caddy' for x in self.calls()))
 def test_upgrade_rollback(self):
  self.assertEqual(self.run_install().returncode,0);before=self.config();before_calls=len(self.calls())
  r=self.run_install(env={'FAIL_CF':'1'});self.assertNotEqual(r.returncode,0);self.assertIn('CF 入口验收失败',r.stderr);self.assertEqual(self.config(),before)
  old=before.splitlines()[0].split()[1]
  self.assertFalse(any(x[:2]==['rm','-f'] and x[-1]==old for x in self.calls()[before_calls:]))
 def test_new_failure_removes_routes(self):
  r=self.run_install(env={'FAIL_CF':'1'});self.assertNotEqual(r.returncode,0);self.assertFalse((self.p/'state/sites/direct.example.com.caddy').exists())
 def test_existing_other_cf_conflict(self):
  sites=self.p/'state/sites';sites.mkdir(parents=True);(sites/'other.caddy').write_text('cf.example.com {\n}\n')
  r=self.run_install();self.assertNotEqual(r.returncode,0);self.assertIn('其他站点',r.stderr)
 def test_legacy_alias_migration(self):
  self.assertEqual(self.run_install(dual=False).returncode,0);before=self.config();backend=next(x.split()[1] for x in before.splitlines() if 'reverse_proxy' in x)
  alias=self.p/'state/sites/cf.example.com.caddy';old='# CF alias of direct.example.com\nhttp://cf.example.com {\n reverse_proxy '+backend+' {\n }\n}\n';alias.write_text(old)
  self.assertNotEqual(self.run_install(env={'FAIL_CF':'1'}).returncode,0);self.assertEqual(alias.read_text(),old);self.assertEqual(self.config(),before)
  r=self.run_install();self.assertEqual(r.returncode,0,r.stderr);self.assertFalse(alias.exists());self.assertIn('http://cf.example.com',self.config())
 def test_single_compatibility(self):
  r=self.run_install(dual=False);self.assertEqual(r.returncode,0,r.stderr);self.assertNotIn('http://cf.',self.config());self.assertEqual(len(r.stdout.splitlines()),1)
 def test_worker_local(self):
  r=self.run_install(env={'WORKER':'1'},image='ghcr.io/yjscms/worker7m:v1.0.0');self.assertEqual(r.returncode,0,r.stderr)
  self.assertEqual(len(r.stdout.splitlines()),4)
  backendrun=next(x for x in self.calls() if x[:1]==['run'] and x[x.index('--name')+1]!='vps-proxy-caddy');self.assertIn('RESOLVE_API_BASE=',backendrun)
 def test_invalid_domains(self):
  r=subprocess.run(['bash',str(self.script),'same.example.com','same.example.com','missav:test'],capture_output=True,text=True,env=self.env);self.assertNotEqual(r.returncode,0);self.assertFalse((self.p/'calls').exists())
if __name__=='__main__':unittest.main()
