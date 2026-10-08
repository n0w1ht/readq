"""A stand-in for Anki's AnkiConnect add-on, for readq's tests.

Usage: python3 fake-ankiconnect.py PORT LOGFILE

Answers version, createDeck, storeMediaFile and addNote like AnkiConnect 6, logging each
request as a line of JSON.  A note whose first field contains DUPLICATE
is refused as a duplicate; one containing BROKEN fails with an error.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port, log = int(sys.argv[1]), sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        req = json.loads(body.decode("utf-8"))
        with open(log, "a", encoding="utf-8") as f:
            f.write(json.dumps(req) + "\n")
        action, result, error = req.get("action"), None, None
        if action == "version":
            result = 6
        elif action == "createDeck":
            result = 1
        elif action == "storeMediaFile":
            result = req["params"]["filename"]
        elif action == "addNote":
            first = list(req["params"]["note"]["fields"].values())[0]
            if "DUPLICATE" in first:
                error = "cannot create note because it is a duplicate"
            elif "BROKEN" in first:
                error = "model was not found: Basic"
            else:
                result = 1496198395707
        else:
            error = "unsupported action"
        out = json.dumps({"result": result, "error": error}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", port), Handler).serve_forever()
