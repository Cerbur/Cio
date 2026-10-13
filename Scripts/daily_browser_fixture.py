#!/usr/bin/env python3
"""Loopback-only daily browser acceptance fixture. No accounts or real uploads."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import time
from urllib.parse import urlparse

PAGE = r'''<!doctype html><meta charset="utf-8"><title>Cio P0 Acceptance</title>
<style>body{font:17px system-ui;max-width:850px;margin:32px}button,a,input{margin:8px;padding:8px}#drop{border:2px dashed #888;padding:24px}pre{white-space:pre-wrap}</style>
<h1>Cio P0 Acceptance</h1><p>Loopback fixtures only. Permission media devices are synthetic.</p>
<button onclick="media({video:true})">Camera</button><button onclick="media({audio:true})">Microphone</button>
<button onclick="screenShare()">Screen picker</button><button onclick="stop()">Stop capture</button>
<button onclick="Notification.requestPermission().then(p=>log('Notification: '+p))">Notification</button>
<button onclick="navigator.geolocation.getCurrentPosition(p=>log('Location granted'),e=>log('Location: '+e.code))">Location</button>
<p><input aria-label="Upload fixture files" type="file" multiple onchange="upload(this.files)"></p>
<div id="drop">Drop fixture files here</div>
<p><a href="/download" download>Download fixture</a><a href="/slow" download>Slow download</a><a href="/very-slow" download>Long download</a><a href="/broken" download>Interrupted download</a>
<button onclick="blobDownload()">Blob download</button></p>
<p><a href="mailto:cio-test@example.invalid">External mail link</a><a href="/second?value=%2F%26#exact">Second page</a></p>
<pre id="results" aria-live="polite">Ready</pre>
<script>
let stream;function log(s){results.textContent+='\n'+s}
async function media(c){try{stream=await navigator.mediaDevices.getUserMedia(c);log('Media granted: '+stream.getTracks().map(t=>t.kind).join(','))}catch(e){log('Media: '+e.name)}}
async function screenShare(){try{stream=await navigator.mediaDevices.getDisplayMedia({video:true});log('Screen granted')}catch(e){log('Screen: '+e.name)}}
function stop(){if(stream)stream.getTracks().forEach(t=>t.stop());log('Capture stopped')}
async function upload(files){for(const f of files){const r=await fetch('/upload',{method:'POST',body:f});log('Uploaded '+f.name+': '+await r.text())}}
drop.ondragover=e=>e.preventDefault();drop.ondrop=e=>{e.preventDefault();upload(e.dataTransfer.files)};
function blobDownload(){const a=document.createElement('a');a.href=URL.createObjectURL(new Blob(['Cio blob acceptance\n'],{type:'text/plain'}));a.download='cio-blob.txt';a.click();setTimeout(()=>URL.revokeObjectURL(a.href),10000)}
</script>'''

class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlparse(self.path).path
        if path in ('/download', '/slow', '/very-slow', '/broken'):
            size = 32768 if path == '/download' else 8388608
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Disposition', 'attachment; filename="cio-fixture.bin"')
            self.send_header('Content-Length', str(size))
            self.end_headers()
            try:
                for offset in range(0, size, 32768):
                    self.wfile.write(bytes(i % 251 for i in range(offset, offset + 32768)))
                    self.wfile.flush()
                    if path == '/broken':
                        self.close_connection = True
                        return
                    if path in ('/slow', '/very-slow'):
                        time.sleep(.5 if path == '/very-slow' else .12)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        payload = PAGE.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        payload = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        result = b'PASS' if payload in (b'Cio upload acceptance\n', b'Cio second upload\n') else b'Unexpected fixture bytes'
        self.send_response(200)
        self.end_headers()
        self.wfile.write(result)
        print('upload-bytes', len(payload), result.decode(), flush=True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=18766)
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', args.port), Fixture)
    print('Fixture http://127.0.0.1:' + str(server.server_port), flush=True)
    server.serve_forever()
