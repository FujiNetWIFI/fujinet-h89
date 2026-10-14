#!/usr/bin/env python3
"""http-put-server.py PORT DIR LOG: a web server on 127.0.0.1:PORT for the
NPIP tests. GET serves DIR, as python's http.server does; PUT writes the
body to DIR, under the last part of the path. Each request's method, path
and status go to LOG, a line each, so a test can see what never came.

Copyright (C) 2026 Thomas Cherryhomes
SPDX-License-Identifier: GPL-3.0-or-later
"""
import functools
import http.server
import os
import sys


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_request(self, code='-', size='-'):
        with open(LOG, 'a') as f:
            f.write('%s %s %s\n' % (self.command, self.path, code))

    def do_PUT(self):
        if self.headers.get('Transfer-Encoding', '').lower() == 'chunked':
            body = b''
            while True:
                size = int(self.rfile.readline().split(b';')[0], 16)
                if size == 0:
                    self.rfile.readline()
                    break
                body += self.rfile.read(size)
                self.rfile.readline()
        else:
            body = self.rfile.read(int(self.headers.get('Content-Length') or 0))
        with open(os.path.join(DIR, os.path.basename(self.path)), 'wb') as f:
            f.write(body)
        self.send_response(201)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_DELETE(self):
        self.send_response(405)
        self.send_header('Content-Length', '0')
        self.end_headers()


if __name__ == '__main__':
    PORT, DIR, LOG = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    handler = functools.partial(Handler, directory=DIR)
    http.server.ThreadingHTTPServer(('127.0.0.1', PORT), handler).serve_forever()
