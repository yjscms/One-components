"""Optional native Caddy integration: CADDY_BIN=/path/to/caddy python3 -m unittest discover -s test -v.
All origins and listeners here are local fixtures, never production services.
"""
import http.server, os, pathlib, socket, subprocess, threading, time, unittest, urllib.error, urllib.request
import test_install
@unittest.skipUnless(os.environ.get('CADDY_BIN'), 'Set CADDY_BIN for native proxy tests')
class LibraryProxy(unittest.TestCase):
 def test_generated_config_preserves_media_and_error_semantics(self):
  fixture=test_install.Install();fixture.setUp();server=None;process=None
  def free():
   with socket.socket() as sock:sock.bind(('127.0.0.1',0));return sock.getsockname()[1]
  upstream_port,port=free(),free();seen=[];media=(b'G'+b'\0'*187)*8
  class Origin(http.server.BaseHTTPRequestHandler):
   def log_message(self,*args):pass
   def do_GET(self):
    seen.append((self.path,dict(self.headers)))
    if '/missing' in self.path:status,body=404,b'not found'
    elif 'index.m3u8' in self.path:status,body=200,b'#EXTM3U\n#EXTINF:6,\nsegment.webp\n'
    else:status,body=(206,media[:377]) if self.headers.get('Range') else (200,media)
    self.send_response(status);self.send_header('Content-Length',str(len(body)));self.send_header('Cache-Control','public, max-age=9999');self.send_header('Access-Control-Allow-Origin','https://wrong.example')
    if status==206:self.send_header('Content-Range','bytes 0-376/'+str(len(media)))
    self.end_headers();self.wfile.write(body)
  try:
   r=fixture.run_install(env={'LIBRARY':'1'},image='caddy:2-alpine',extra=['--service','library','--upstream','https://origin.example.com','--verify-path','/v/k1/a/index.m3u8']);self.assertEqual(r.returncode,0,r.stderr)
   config=next((fixture.p/'state/backends').glob('*.caddy')).read_text().replace(':8080 {','http://127.0.0.1:'+str(port)+' {').replace('https://origin.example.com','http://127.0.0.1:'+str(upstream_port))
   server=http.server.ThreadingHTTPServer(('127.0.0.1',upstream_port),Origin);threading.Thread(target=server.serve_forever,daemon=True).start()
   path=fixture.p/'native.Caddyfile';path.write_text(config)
   env=dict(os.environ,XDG_CONFIG_HOME=str(fixture.p/'config'),XDG_DATA_HOME=str(fixture.p/'data'))
   process=subprocess.Popen([os.environ['CADDY_BIN'],'run','--config',str(path),'--adapter','caddyfile'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,env=env)
   def request(path,method='GET',headers=None):
    req=urllib.request.Request('http://127.0.0.1:'+str(port)+path,method=method,headers=headers or {})
    try:r=urllib.request.urlopen(req,timeout=5)
    except urllib.error.HTTPError as e:r=e
    with r:return r.status,r.headers,r.read()
   for i in range(50):
    try:request('/healthz');break
    except (OSError,urllib.error.URLError):time.sleep(.1)
   status,headers,body=request('/v/k1/signed/index.m3u8?sig=abc&x=1')
   self.assertEqual(status,200);self.assertTrue(body.startswith(b'#EXTM3U'));self.assertEqual(headers.get_all('Access-Control-Allow-Origin'),['*']);self.assertEqual(headers['Cache-Control'],'public, max-age=9999')
   self.assertEqual(seen[-1][0],'/v/k1/signed/index.m3u8?sig=abc&x=1');self.assertEqual(seen[-1][1]['Host'],'origin.example.com');self.assertEqual(seen[-1][1]['Accept-Encoding'],'identity;q=1, *;q=0')
   status,headers,body=request('/v/k1/a/segment.webp',headers={'Range':'bytes=0-376'});self.assertEqual(status,206);self.assertEqual(len(body),377);self.assertIn('Content-Range',headers);self.assertEqual(seen[-1][1]['Range'],'bytes=0-376')
   status,headers,body=request('/v/missing.webp');self.assertEqual(status,404);self.assertEqual(headers['Cache-Control'],'no-store');self.assertEqual(headers.get_all('Access-Control-Allow-Origin'),['*'])
   count=len(seen);status,headers,body=request('/secret');self.assertEqual(status,404);self.assertEqual(len(seen),count)
   status,headers,body=request('/v/a/segment.webp',method='OPTIONS');self.assertEqual(status,204);self.assertEqual(len(seen),count);self.assertEqual(headers['Access-Control-Allow-Origin'],'*')
  finally:
   if process:process.terminate();process.wait(timeout=5)
   if server:server.shutdown();server.server_close()
   fixture.tearDown()
